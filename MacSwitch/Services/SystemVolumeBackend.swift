import CoreAudio
import Foundation

struct SystemVolumeSnapshot: Equatable, Sendable {
    var outputVolume: Double
    var alertVolume: Double
    var isMuted: Bool
    var deviceID: AudioObjectID
    var deviceName: String
    var outputAvailability: SwitchAvailability = .available
}

@MainActor
protocol SystemVolumeBackend: AnyObject {
    /// A request to refresh. Notifications themselves never change app targets.
    var onChange: (@MainActor () -> Void)? { get set }
    func read() async throws -> SystemVolumeSnapshot
    func setOutputVolume(_ value: Double, expectedDeviceID: AudioObjectID?) async throws -> SystemVolumeSnapshot
    func setAlertVolume(_ value: Double) async throws -> SystemVolumeSnapshot
    func shutdown()
}

struct SystemVolumeDevice: Equatable, Sendable {
    var id: AudioObjectID
    var name: String
    var outputAvailability: SwitchAvailability = .available
}

@MainActor
protocol SystemVolumeHardware: AnyObject {
    var onChange: (@MainActor () -> Void)? { get set }
    func currentDevice() throws -> SystemVolumeDevice
    func observe(deviceID: AudioObjectID) throws
    func shutdown()
}

/// The scripting addition exposes the same 0...100 base-output and alert values
/// as macOS. HAL supplies device identity, capability, and prompt notifications.
/// Alert preferences also need polling: there is no public alert-volume HAL
/// property that is guaranteed to issue a notification for this setting.
@MainActor
final class AppleScriptSystemVolumeBackend: SystemVolumeBackend {
    typealias ScriptRunner = @MainActor (String) async throws -> String
    var onChange: (@MainActor () -> Void)?

    private let hardware: any SystemVolumeHardware
    private let runScript: ScriptRunner
    private let pollInterval: Duration?
    private var pollTask: Task<Void, Never>?
    private var stopped = false
    private var occupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        hardware: (any SystemVolumeHardware)? = nil,
        pollInterval: Duration? = .seconds(1),
        runScript: @escaping ScriptRunner = AppleScriptSystemVolumeBackend.executeScript
    ) {
        self.hardware = hardware ?? CoreAudioSystemVolumeHardware()
        self.pollInterval = pollInterval
        self.runScript = runScript
        self.hardware.onChange = { [weak self] in self?.onChange?() }
    }

    func read() async throws -> SystemVolumeSnapshot {
        await acquire()
        defer { release() }
        return try await readCurrent()
    }

    func setOutputVolume(_ value: Double, expectedDeviceID: AudioObjectID? = nil) async throws -> SystemVolumeSnapshot {
        let target = try Self.percent(value)
        await acquire()
        defer { release() }
        try ensureRunning()
        let device = try hardware.currentDevice()
        if let expectedDeviceID, expectedDeviceID != device.id { throw deviceChanged() }
        switch device.outputAvailability {
        case .available: break
        case .unsupported(let reason): throw SwitchFailure.unsupported(reason)
        case .unauthorized(let reason): throw SwitchFailure.unauthorized(reason)
        }
        // Recheck immediately before the scripting addition executes. macOS does
        // not offer an atomic AppleScript "only if this device is still default".
        guard try hardware.currentDevice().id == device.id else { throw deviceChanged() }
        // On current macOS an output-volume write can unmute despite the
        // documented default for the omitted mute parameter. Capture and supply
        // mute inside this same script so F10 does not lose its state on drag.
        _ = try await runScript(Self.outputScript(target))
        try ensureRunning()
        guard try hardware.currentDevice().id == device.id else { throw deviceChanged() }
        // The hardware may quantize the requested percentage. Return the real
        // readback, including mute, rather than falsely asserting exact equality.
        return try await readCurrent(expectedDeviceID: device.id)
    }

    func setAlertVolume(_ value: Double) async throws -> SystemVolumeSnapshot {
        let target = try Self.percent(value)
        await acquire()
        defer { release() }
        try ensureRunning()
        // Deliberately supplies only the alert parameter. Output, input, and
        // mute remain independent per Apple's set volume command contract.
        _ = try await runScript("set volume alert volume \(target)")
        return try await readCurrent()
    }

    func shutdown() {
        stopped = true
        pollTask?.cancel()
        pollTask = nil
        hardware.onChange = nil
        hardware.shutdown()
        onChange = nil
    }

    private func readCurrent(expectedDeviceID: AudioObjectID? = nil) async throws -> SystemVolumeSnapshot {
        try ensureRunning()
        let device = try hardware.currentDevice()
        if let expectedDeviceID, device.id != expectedDeviceID { throw deviceChanged() }
        try hardware.observe(deviceID: device.id)
        startPollingIfNeeded()
        let settings = try Self.parseSettings(try await runScript(Self.readScript))
        try ensureRunning()
        guard try hardware.currentDevice().id == device.id else { throw deviceChanged() }
        return SystemVolumeSnapshot(
            outputVolume: settings.outputVolume,
            alertVolume: settings.alertVolume,
            isMuted: settings.isMuted,
            deviceID: device.id,
            deviceName: device.name,
            outputAvailability: device.outputAvailability
        )
    }

    private func startPollingIfNeeded() {
        guard pollTask == nil, let pollInterval else { return }
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: pollInterval) } catch { return }
                guard !Task.isCancelled, let self, !self.stopped else { return }
                self.onChange?()
            }
        }
    }

    // Serializes this continuous-control lane independently of switch commands.
    // In particular, a slow earlier osascript must not finish after a later write.
    private func acquire() async {
        if occupied { await withCheckedContinuation { waiters.append($0) } }
        else { occupied = true }
    }

    private func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().resume() }
    }

    private func ensureRunning() throws {
        try Task.checkCancellation()
        guard !stopped else { throw SwitchFailure.failed("系统音量服务已停止。") }
    }

    private func deviceChanged() -> SwitchFailure {
        onChange?()
        return .failed("默认输出设备已更换，请等待音量刷新后重新操作。")
    }

    private static func percent(_ value: Double) throws -> Int {
        guard value.isFinite else { throw SwitchFailure.failed("音量必须是 0～100 之间的有限数值。") }
        return Int(VolumeLinkState.clamp(value).rounded())
    }

    static let readScript = """
    set v to get volume settings
    return (output volume of v as text) & "|" & (alert volume of v as text) & "|" & (output muted of v as text)
    """

    static func outputScript(_ target: Int) -> String {
        """
        set preservedMute to output muted of (get volume settings)
        set volume output volume \(target) output muted preservedMute
        """
    }

    static func parseSettings(_ text: String) throws -> (outputVolume: Double, alertVolume: Double, isMuted: Bool) {
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard fields.count == 3,
              let output = Int(fields[0]), (0...100).contains(output),
              let alert = Int(fields[1]), (0...100).contains(alert),
              let muted = Bool(fields[2]) else {
            throw SwitchFailure.failed("无法解析 macOS 返回的系统音量，已保留实际设置。")
        }
        return (Double(output), Double(alert), muted)
    }

    private static func executeScript(_ script: String) async throws -> String {
        let result = try await ProcessRunner.run("/usr/bin/osascript", ["-e", script], timeout: 5)
        guard result.status == 0 else {
            throw SwitchFailure.failed("读写 macOS 系统音量失败：\(result.output)")
        }
        return result.output
    }
}

@MainActor
final class CoreAudioSystemVolumeHardware: SystemVolumeHardware {
    var onChange: (@MainActor () -> Void)?

    private struct Subscription {
        var object: AudioObjectID
        var address: AudioObjectPropertyAddress
        var block: AudioObjectPropertyListenerBlock
    }

    private var subscriptions: [Subscription] = []
    private var observedDevice: AudioObjectID?

    func currentDevice() throws -> SystemVolumeDevice {
        var defaultAddress = address(kAudioHardwarePropertyDefaultOutputDevice)
        let device = try uint32(AudioObjectID(kAudioObjectSystemObject), address: &defaultAddress)
        guard device != kAudioObjectUnknown else {
            return SystemVolumeDevice(id: device, name: "无输出设备", outputAvailability: .unsupported("未找到默认输出设备。"))
        }
        var aliveAddress = address(kAudioDevicePropertyDeviceIsAlive)
        guard try uint32(device, address: &aliveAddress) != 0 else {
            throw SwitchFailure.failed("输出设备已断开，请连接后重试。")
        }
        var nameAddress = address(kAudioObjectPropertyName)
        var nameReference: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &nameReference))
        let name = nameReference?.takeRetainedValue() as String? ?? "输出设备"
        var hasVolume = false
        var writable = false
        for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
            var candidate = address(kAudioDevicePropertyVolumeScalar, output: true, element: element)
            guard AudioObjectHasProperty(device, &candidate) else { continue }
            hasVolume = true
            var settable: DarwinBoolean = false
            try check(AudioObjectIsPropertySettable(device, &candidate, &settable))
            writable = writable || settable.boolValue
        }
        let availability: SwitchAvailability = !hasVolume
            ? .unsupported("此输出设备未提供系统音量控制，请使用设备自身的音量控制。")
            : writable ? .available : .unsupported("此输出设备的系统音量为只读。")
        return SystemVolumeDevice(id: device, name: name, outputAvailability: availability)
    }

    func observe(deviceID: AudioObjectID) throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        if !subscriptions.contains(where: { $0.object == system }) {
            do {
                for property in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
                    try add(object: system, address: address(property))
                }
            } catch {
                removeAll()
                throw error
            }
        }
        guard observedDevice != deviceID else { return }
        removeDeviceListeners()
        guard deviceID != kAudioObjectUnknown else { return }
        do {
            var candidates = [
                address(kAudioObjectPropertyName),
                address(kAudioDevicePropertyDeviceIsAlive),
                address(kAudioDevicePropertyDeviceHasChanged)
            ]
            for element: UInt32 in [kAudioObjectPropertyElementMain, 1, 2] {
                candidates.append(address(kAudioDevicePropertyVolumeScalar, output: true, element: element))
                candidates.append(address(kAudioDevicePropertyMute, output: true, element: element))
            }
            for var candidate in candidates where AudioObjectHasProperty(deviceID, &candidate) {
                try add(object: deviceID, address: candidate)
            }
            observedDevice = deviceID
        } catch {
            removeDeviceListeners()
            throw error
        }
    }

    func shutdown() {
        removeAll()
        onChange = nil
    }

    private func removeAll() {
        for var subscription in subscriptions {
            AudioObjectRemovePropertyListenerBlock(subscription.object, &subscription.address, .main, subscription.block)
        }
        subscriptions.removeAll()
        observedDevice = nil
    }

    private func removeDeviceListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for var subscription in subscriptions where subscription.object != system {
            AudioObjectRemovePropertyListenerBlock(subscription.object, &subscription.address, .main, subscription.block)
        }
        subscriptions.removeAll { $0.object != system }
        observedDevice = nil
    }

    private func add(object: AudioObjectID, address: AudioObjectPropertyAddress) throws {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.onChange?() }
        }
        try check(AudioObjectAddPropertyListenerBlock(object, &address, .main, block))
        subscriptions.append(Subscription(object: object, address: address, block: block))
    }

    private func address(_ selector: AudioObjectPropertySelector, output: Bool = false, element: UInt32 = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: output ? kAudioDevicePropertyScopeOutput : kAudioObjectPropertyScopeGlobal, mElement: element)
    }

    private func uint32(_ object: AudioObjectID, address: inout AudioObjectPropertyAddress) throws -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value))
        return value
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw SwitchFailure.failed("读取或监听系统音量设备失败。（\(status)）") }
    }
}
