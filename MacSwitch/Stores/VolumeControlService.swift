import AppKit
import CoreAudio
import Observation
import OSLog

@MainActor
protocol ApplicationAudioMixing: AnyObject {
    var status: ApplicationAudioMixerStatus { get }
    func start(application: DiscoveredAudioApplication, outputDevice: AudioObjectID, gain: AudioGainResult) throws
    func updateGain(_ result: AudioGainResult)
    func stop()
    func validateRouteAndHealth() -> String?
}

extension ApplicationAudioMixer: ApplicationAudioMixing {}

struct ApplicationVolumeRow: Identifiable {
    let application: DiscoveredAudioApplication
    var target: Double
    var message: String?
    var isRunning: Bool
    var isLimited: Bool
    var isApproximate: Bool
    var id: String { application.id }
}

/// Continuous volume commands have their own coalescing lane. Only confirmed
/// readbacks enter VolumeLinkState; no optimistic UI value can apply a delta.
@MainActor @Observable
final class VolumeControlService: SwitchService {
    let id: FeatureID = .volumeControl
    var onChange: (@MainActor () -> Void)?
    private(set) var isEnabled = false
    private(set) var system: SystemVolumeSnapshot?
    private(set) var applications: [ApplicationVolumeRow] = []
    private(set) var systemError: String?
    private(set) var applicationMessage: String?
    private(set) var cleanupMessage: String?
    private(set) var link = VolumeLinkState()
    private(set) var stagedOutput: Double?
    private(set) var stagedAlert: Double?
    var outputValue: Double { stagedOutput ?? system?.outputVolume ?? 0 }
    var alertValue: Double { stagedAlert ?? system?.alertVolume ?? 0 }

    @ObservationIgnored private let makeBackend: @MainActor () -> any SystemVolumeBackend
    @ObservationIgnored private let discover: @MainActor (AudioObjectID) -> [DiscoveredAudioApplication]
    @ObservationIgnored private let makeMixer: @MainActor () -> any ApplicationAudioMixing
    @ObservationIgnored private let curve: @MainActor (AudioObjectID, Float) -> Float?
    @ObservationIgnored private var backend: (any SystemVolumeBackend)?
    @ObservationIgnored private var mixers: [String: any ApplicationAudioMixing] = [:]
    @ObservationIgnored private var attachedProcesses: [String: [AudioObjectID]] = [:]
    @ObservationIgnored private var failures: [String: String] = [:]
    @ObservationIgnored private var cleanupPending: [any ApplicationAudioMixing] = []
    @ObservationIgnored private var cleanupTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var retiringWorkers: [UUID: Task<Void, Never>] = [:]
    var hasInFlightOperations: Bool { worker != nil || !retiringWorkers.isEmpty }
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var pendingOutput: (value: Double, device: AudioObjectID)?
    @ObservationIgnored private var pendingAlert: Double?
    @ObservationIgnored private var needsRefresh = false
    @ObservationIgnored private var sleeping = false
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private let automaticallyPoll: Bool
    @ObservationIgnored private let logger = Logger(subsystem: "local.herman.MacSwitch", category: "AudioLifecycle")

    init(makeBackend: @escaping @MainActor () -> any SystemVolumeBackend = { AppleScriptSystemVolumeBackend() },
         discover: (@MainActor (AudioObjectID) -> [DiscoveredAudioApplication])? = nil,
         makeMixer: @escaping @MainActor () -> any ApplicationAudioMixing = { ApplicationAudioMixer() },
         curve: @escaping @MainActor (AudioObjectID, Float) -> Float? = { AudioHAL.volumeDecibels(device: $0, scalar: $1) },
         automaticallyPoll: Bool = true) {
        self.makeBackend = makeBackend
        let discovery = ApplicationAudioDiscovery()
        self.discover = discover ?? { discovery.discover(defaultDevice: $0) }
        self.makeMixer = makeMixer
        self.curve = curve
        self.automaticallyPoll = automaticallyPoll
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspendForSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeAfterSleep() }
        })
    }

    func read() async throws -> SwitchSnapshot {
        SwitchSnapshot(isEnabled: isEnabled, detail: isEnabled ? "系统音量与应用目标音量" : "展开提醒、输出与应用音量")
    }

    func setEnabled(_ enabled: Bool) async throws -> SwitchSnapshot {
        guard !stopping else { throw SwitchFailure.failed("音量服务已停止。") }
        if !enabled {
            stopSession()
            await finishRetiringWorkers()
        } else if !isEnabled {
            await finishRetiringWorkers()
            guard !stopping else { throw SwitchFailure.failed("音量服务已停止。") }
            retryCleanup()
            guard cleanupPending.isEmpty else { throw SwitchFailure.failed(cleanupMessage ?? "音频资源正在释放，请稍后重试。") }
            let newBackend = makeBackend()
            backend = newBackend
            do {
                let initial = try await newBackend.read()
                guard !stopping else { newBackend.shutdown(); throw SwitchFailure.failed("音量服务已停止。") }
                generation += 1
                link.reset(outputVolume: initial.outputVolume, isMuted: initial.isMuted)
                system = initial
                systemError = nil
                applicationMessage = nil
                isEnabled = true
                newBackend.onChange = { [weak self] in self?.requestRefresh() }
                refreshApplications()
                startPolling()
            } catch {
                newBackend.shutdown()
                backend = nil
                throw error
            }
        }
        return try await read()
    }

    func setOutputVolume(_ value: Double) {
        guard isEnabled, !sleeping, value.isFinite, let system, system.outputAvailability == .available else { return }
        let value = VolumeLinkState.clamp(value).rounded()
        stagedOutput = value
        pendingOutput = (value, system.deviceID)
        startWorker()
    }

    func setAlertVolume(_ value: Double) {
        guard isEnabled, !sleeping, value.isFinite else { return }
        let value = VolumeLinkState.clamp(value).rounded()
        stagedAlert = value
        pendingAlert = value
        startWorker()
    }

    func setApplicationVolume(_ value: Double, for id: String) {
        guard isEnabled, value.isFinite else { return }
        link.setApplicationVolume(value.rounded(), for: id)
        updateApplicationRows()
    }

    func requestRefresh() {
        guard isEnabled, !sleeping else { return }
        needsRefresh = true
        startWorker()
    }

    func retryApplicationAudio() {
        guard isEnabled, !sleeping else { return }
        failures.removeAll()
        applicationMessage = nil
        refreshApplications()
    }

    /// Also used by the device validation harness, without opening the panel.
    func refreshApplications() {
        guard isEnabled, !sleeping, let system else { return }
        let discovered = discover(system.deviceID)
        let live = Set(discovered.map(\.id))
        for id in Array(mixers.keys) where !live.contains(id) {
            stopMixer(id)
            // Targets remain saved for this entire enable session.
        }
        for app in discovered {
            link.addApplication(app.id)
            if attachedProcesses[app.id] != app.processObjectIDs || app.unsupportedReason != nil {
                stopMixer(app.id)
            }
            if let mixer = mixers[app.id], let error = mixer.validateRouteAndHealth() {
                failures[app.id] = error
                stopMixer(app.id)
            }
            guard mixers[app.id] == nil, failures[app.id] == nil, app.unsupportedReason == nil, cleanupPending.isEmpty else { continue }
            let mixer = makeMixer()
            do {
                try mixer.start(application: app, outputDevice: system.deviceID, gain: gain(for: app.id))
                mixers[app.id] = mixer
                attachedProcesses[app.id] = app.processObjectIDs
                logger.info("Mixer started device=\(system.deviceID) processes=\(app.processObjectIDs.count)")
            } catch {
                mixer.stop()
                retainForCleanup(mixer)
                failures[app.id] = error.localizedDescription
                logger.error("Mixer failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        applications = discovered.map {
            ApplicationVolumeRow(application: $0, target: link.applicationTargets[$0.id] ?? system.outputVolume,
                                 message: nil, isRunning: false, isLimited: false, isApproximate: false)
        }
        updateApplicationRows()
        applicationMessage = discovered.isEmpty ? "开始播放声音后，应用会出现在这里。" : nil
    }

    func audioStatus(for id: String) -> ApplicationAudioMixerStatus? { mixers[id]?.status }

    private func gain(for id: String) -> AudioGainResult {
        AudioGain.calculate(targetPercent: link.applicationTargets[id] ?? link.outputVolume,
                            outputPercent: link.outputVolume, muted: link.isMuted,
                            decibels: { [self] scalar in system.flatMap { curve($0.deviceID, scalar) } })
    }

    private func updateApplicationRows() {
        for index in applications.indices {
            let id = applications[index].id
            let result = gain(for: id)
            let mixer = mixers[id]
            mixer?.updateGain(result)
            let status = mixer?.status
            applications[index].target = link.applicationTargets[id] ?? link.outputVolume
            applications[index].isRunning = status?.isRunning ?? false
            applications[index].isLimited = result.isAmplificationLimited || status?.isLimiting == true
            applications[index].isApproximate = result.usesApproximateCurve
            applications[index].message = applications[index].application.unsupportedReason ?? failures[id] ?? status?.message
        }
    }

    private func startWorker() {
        guard worker == nil else { return }
        let current = generation
        // Capture the predecessors before installing the new worker; it must
        // never become its own dependency if sleep immediately retires it.
        let predecessors = Array(retiringWorkers.values)
        worker = Task { [weak self] in
            for task in predecessors { await task.value }
            await self?.drain(generation: current)
        }
    }

    private func drain(generation current: Int) async {
        while current == generation, isEnabled, !sleeping, !Task.isCancelled, let backend {
            do {
                let confirmed: SystemVolumeSnapshot
                if let pending = pendingOutput {
                    pendingOutput = nil
                    confirmed = try await backend.setOutputVolume(pending.value, expectedDeviceID: pending.device)
                    if current == generation, pendingOutput == nil { stagedOutput = nil }
                } else if let pending = pendingAlert {
                    pendingAlert = nil
                    confirmed = try await backend.setAlertVolume(pending)
                    if current == generation, pendingAlert == nil { stagedAlert = nil }
                } else if needsRefresh {
                    needsRefresh = false
                    confirmed = try await backend.read()
                } else { break }
                guard current == generation, isEnabled, !sleeping else { break }
                apply(confirmed)
                systemError = nil
            } catch {
                guard current == generation, isEnabled, !Task.isCancelled else { break }
                systemError = error.localizedDescription
                if pendingOutput == nil { stagedOutput = nil }
                if pendingAlert == nil { stagedAlert = nil }
                // A partial system write may have succeeded. Reconcile once;
                // failed polling never enters an automatic retry loop.
                if let actual = try? await backend.read(), current == generation, !sleeping { apply(actual) }
            }
        }
        if current == generation { worker = nil }
    }

    private func apply(_ confirmed: SystemVolumeSnapshot) {
        if system?.deviceID != confirmed.deviceID {
            stopAllMixers()
            failures.removeAll()
            pendingOutput = nil
            stagedOutput = nil
        }
        system = confirmed
        link.applySystemOutput(confirmed.outputVolume, isMuted: confirmed.isMuted)
        refreshApplications()
    }

    private func startPolling() {
        guard automaticallyPoll else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, self.isEnabled else { return }
                self.refreshApplications()
            }
        }
    }

    func suspendForSleep() {
        logger.info("Sleep cleanup begin mixers=\(self.mixers.count)")
        sleeping = true
        generation += 1
        retireWorker()
        needsRefresh = false
        pendingOutput = nil; pendingAlert = nil
        stagedOutput = nil; stagedAlert = nil
        stopAllMixers()
        applicationMessage = "睡眠期间已恢复原声，唤醒后重新检查输出设备。"
        logger.info("Sleep cleanup complete pending=\(self.cleanupPending.count)")
    }

    func resumeAfterSleep() {
        logger.info("Wake refresh requested enabled=\(self.isEnabled)")
        sleeping = false
        failures.removeAll()
        requestRefresh()
    }

    private func stopMixer(_ id: String) {
        guard let mixer = mixers[id] else { return }
        mixer.stop()
        if let error = mixer.status.message { failures[id] = error }
        retainForCleanup(mixer)
        mixers[id] = nil
        attachedProcesses[id] = nil
    }

    private func stopAllMixers() { for id in Array(mixers.keys) { stopMixer(id) } }

    private func retainForCleanup(_ mixer: any ApplicationAudioMixing) {
        guard mixer.status.requiresCleanup else { return }
        cleanupPending.append(mixer)
        cleanupMessage = "音频恢复尚未完全确认，正在重试释放；若持续出现，请退出 MacSwitch。"
        guard cleanupTask == nil else { return }
        cleanupTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self else { return }
                self.retryCleanup()
                if self.cleanupPending.isEmpty { self.cleanupTask = nil; return }
            }
        }
    }

    private func retryCleanup() {
        for mixer in cleanupPending { mixer.stop() }
        cleanupPending.removeAll { !$0.status.requiresCleanup }
        if cleanupPending.isEmpty { cleanupMessage = nil }
    }

    private func stopSession() {
        generation += 1
        isEnabled = false
        pollTask?.cancel(); pollTask = nil
        retireWorker()
        backend?.onChange = nil
        backend?.shutdown(); backend = nil
        stopAllMixers()
        pendingOutput = nil; pendingAlert = nil; needsRefresh = false
        stagedOutput = nil; stagedAlert = nil
        link.reset()
        applications.removeAll()
        failures.removeAll()
        applicationMessage = nil
        onChange?()
    }

    private func retireWorker() {
        if let worker {
            let id = UUID()
            worker.cancel()
            retiringWorkers[id] = worker
            Task { [weak self] in
                await worker.value
                self?.retiringWorkers[id] = nil
            }
        }
        worker = nil
    }

    private func finishRetiringWorkers() async {
        let pending = retiringWorkers
        for (id, task) in pending {
            await task.value
            retiringWorkers[id] = nil
        }
    }

    func waitUntilIdle() async {
        await worker?.value
        await finishRetiringWorkers()
    }

    func shutdown() {
        stopping = true
        stopSession()
        retryCleanup()
        cleanupTask?.cancel(); cleanupTask = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}
