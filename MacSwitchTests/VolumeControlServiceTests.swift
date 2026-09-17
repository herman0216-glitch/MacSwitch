import CoreAudio
import Testing
@testable import MacSwitch

@MainActor
struct VolumeControlServiceTests {
    @Test func continuousDragCoalescesAndOnlyReadbacksLinkOnce() async throws {
        let fixture = VolumeFixture()
        let service = fixture.service()
        _ = try await service.setEnabled(true)
        service.setApplicationVolume(80, for: "a")
        fixture.backend.pauseWrite = true
        service.setOutputVolume(90)
        while fixture.backend.continuation == nil { await Task.yield() }
        service.setOutputVolume(85)
        service.setOutputVolume(80)
        #expect(service.link.applicationTargets["a"] == 80)
        fixture.backend.continuation?.resume(); fixture.backend.continuation = nil
        await service.waitUntilIdle()
        #expect(fixture.backend.writes == [90, 80])
        #expect(service.link.applicationTargets["a"] == 90)
        #expect(service.link.applicationTargets["b"] == 80)
        service.requestRefresh()
        await service.waitUntilIdle()
        #expect(service.link.applicationTargets["a"] == 90)
        service.shutdown()
    }

    @Test func pausesKeepTargetsAndDisablingResetsSession() async throws {
        let fixture = VolumeFixture()
        let service = fixture.service()
        _ = try await service.setEnabled(true)
        service.setApplicationVolume(20, for: "a")
        fixture.apps.removeFirst()
        service.refreshApplications()
        #expect(service.applications.count == 1)
        #expect(service.link.applicationTargets["a"] == 20)
        fixture.apps.insert(VolumeFixture.app("a"), at: 0)
        service.refreshApplications()
        #expect(service.applications.first?.target == 20)
        _ = try await service.setEnabled(false)
        #expect(fixture.mixers.allSatisfy { !$0.status.isRunning })
        #expect(service.link.applicationTargets.isEmpty)
        _ = try await service.setEnabled(true)
        #expect(service.link.applicationTargets["a"] == 60)
        service.shutdown()
    }

    @Test func muteAndZeroPreserveValuesWithoutCrossWrites() async throws {
        let fixture = VolumeFixture()
        let service = fixture.service()
        _ = try await service.setEnabled(true)
        service.setApplicationVolume(85, for: "a")
        fixture.backend.snapshot.isMuted = true
        service.requestRefresh(); await service.waitUntilIdle()
        #expect(service.link.applicationTargets["a"] == 85)
        #expect(fixture.mixers.allSatisfy { $0.gain.linearGain == 0 })
        service.setAlertVolume(18); await service.waitUntilIdle()
        #expect(service.link.outputVolume == 60)
        #expect(fixture.backend.writes.isEmpty)
        fixture.backend.snapshot.outputVolume = 0
        service.requestRefresh(); await service.waitUntilIdle()
        service.setApplicationVolume(78, for: "a")
        #expect(service.link.applicationTargets["a"] == 78)
        #expect(fixture.mixers.allSatisfy { $0.gain.linearGain == 0 })
        service.shutdown()
    }

    @Test func failedCaptureLeavesSystemControlsAndDoesNotLoopPrompts() async throws {
        let fixture = VolumeFixture()
        fixture.failCapture = true
        let service = fixture.service()
        _ = try await service.setEnabled(true)
        #expect(service.isEnabled)
        #expect(service.applications.allSatisfy { $0.message == "capture denied" })
        let attempts = fixture.mixers.count
        for _ in 0..<4 { service.refreshApplications() }
        #expect(fixture.mixers.count == attempts)
        service.setOutputVolume(55); await service.waitUntilIdle()
        service.setAlertVolume(12); await service.waitUntilIdle()
        #expect(service.system?.outputVolume == 55)
        #expect(service.system?.alertVolume == 12)
        fixture.failCapture = false
        service.retryApplicationAudio()
        #expect(service.applications.allSatisfy { $0.isRunning })
        service.shutdown()
    }

    @Test func deviceChangeStopsOldMixersAndBindsOnlyNewDevice() async throws {
        let fixture = VolumeFixture()
        let service = fixture.service()
        _ = try await service.setEnabled(true)
        let old = fixture.mixers
        fixture.backend.snapshot.deviceID = 2
        fixture.backend.snapshot.outputVolume = 40
        service.requestRefresh(); await service.waitUntilIdle()
        #expect(old.allSatisfy { !$0.status.isRunning })
        #expect(fixture.mixers.suffix(2).allSatisfy { $0.device == 2 })
        #expect(service.link.applicationTargets["a"] == 40)
        service.shutdown()
    }

    @Test func sleepRestoresOriginalAudioAndWakeReadsExternalChanges() async throws {
        let fixture = VolumeFixture()
        let service = fixture.service()
        _ = try await service.setEnabled(true)
        service.setApplicationVolume(80, for: "a")
        service.suspendForSleep()
        #expect(fixture.mixers.allSatisfy { !$0.status.isRunning })
        service.setOutputVolume(100)
        #expect(fixture.backend.writes.isEmpty)
        fixture.backend.snapshot.outputVolume = 50
        service.resumeAfterSleep(); await service.waitUntilIdle()
        #expect(service.link.applicationTargets["a"] == 70)
        #expect(service.applications.allSatisfy { $0.isRunning })
        service.shutdown()
    }

    @Test func closingAfterSleepWaitsForPhysicalWriteBeforeNewSession() async throws {
        let fixture = VolumeFixture()
        let service = fixture.service()
        _ = try await service.setEnabled(true)
        fixture.backend.pauseWrite = true
        service.setOutputVolume(90)
        while fixture.backend.continuation == nil { await Task.yield() }
        service.suspendForSleep()
        var closeFinished = false
        let close = Task { _ = try await service.setEnabled(false); closeFinished = true }
        for _ in 0..<5 { await Task.yield() }
        #expect(!closeFinished)
        fixture.backend.continuation?.resume(); fixture.backend.continuation = nil
        try await close.value
        service.resumeAfterSleep()
        _ = try await service.setEnabled(true)
        service.setOutputVolume(20)
        await service.waitUntilIdle()
        #expect(fixture.backend.snapshot.outputVolume == 20)
        #expect(fixture.backend.writes == [90, 20])
        service.shutdown()
    }
}

@MainActor
private final class VolumeFixture {
    let backend = ContinuousVolumeFake()
    var apps = [app("a"), app("b")]
    var mixers: [MixingFake] = []
    var failCapture = false
    static func app(_ id: String) -> DiscoveredAudioApplication {
        DiscoveredAudioApplication(id: id, name: id, bundleURL: nil, processObjectIDs: [id == "a" ? 10 : 11], unsupportedReason: nil)
    }
    func service() -> VolumeControlService {
        VolumeControlService(makeBackend: { self.backend }, discover: { _ in self.apps }, makeMixer: {
            let mixer = MixingFake()
            mixer.fail = self.failCapture
            self.mixers.append(mixer)
            return mixer
        }, curve: { _, scalar in -60 * (1 - scalar) }, automaticallyPoll: false)
    }
}

@MainActor
private final class ContinuousVolumeFake: SystemVolumeBackend {
    var onChange: (@MainActor () -> Void)?
    var snapshot = SystemVolumeSnapshot(outputVolume: 60, alertVolume: 30, isMuted: false, deviceID: 1, deviceName: "Test")
    var writes: [Double] = []
    var pauseWrite = false
    var continuation: CheckedContinuation<Void, Never>?
    func read() async throws -> SystemVolumeSnapshot { snapshot }
    func setOutputVolume(_ value: Double, expectedDeviceID: AudioObjectID?) async throws -> SystemVolumeSnapshot {
        writes.append(value)
        if pauseWrite { pauseWrite = false; await withCheckedContinuation { continuation = $0 } }
        snapshot.outputVolume = value
        return snapshot
    }
    func setAlertVolume(_ value: Double) async throws -> SystemVolumeSnapshot { snapshot.alertVolume = value; return snapshot }
    func shutdown() {}
}

@MainActor
private final class MixingFake: ApplicationAudioMixing {
    var fail = false
    var device: AudioObjectID?
    var gain = AudioGainResult(linearGain: 1, isAmplificationLimited: false, usesApproximateCurve: false)
    var status = ApplicationAudioMixerStatus(isRunning: false, message: nil, hasReceivedAudio: false, hasReceivedCallbacks: false,
        isLimiting: false, inputPeak: 0, outputPeak: 0, callbackCount: 0)
    func start(application: DiscoveredAudioApplication, outputDevice: AudioObjectID, gain: AudioGainResult) throws {
        if fail { throw SwitchFailure.unauthorized("capture denied") }
        device = outputDevice
        self.gain = gain
        status = ApplicationAudioMixerStatus(isRunning: true, message: nil, hasReceivedAudio: true, hasReceivedCallbacks: true,
            isLimiting: false, inputPeak: 0.1, outputPeak: 0.1, callbackCount: 1)
    }
    func updateGain(_ result: AudioGainResult) { gain = result }
    func stop() {
        status = ApplicationAudioMixerStatus(isRunning: false, message: nil, hasReceivedAudio: false, hasReceivedCallbacks: false,
            isLimiting: false, inputPeak: 0, outputPeak: 0, callbackCount: 0)
    }
    func validateRouteAndHealth() -> String? { nil }
}
