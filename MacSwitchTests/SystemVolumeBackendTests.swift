import CoreAudio
import Testing
@testable import MacSwitch

@MainActor
struct SystemVolumeBackendTests {
    @Test func readUsesActualSystemPercentagesAndKeepsMutedBaseVolume() async throws {
        let script = VolumeScriptFake()
        script.isMuted = true
        let hardware = VolumeHardwareFake()
        let backend = makeBackend(script, hardware)
        let snapshot = try await backend.read()
        #expect(snapshot.outputVolume == 60)
        #expect(snapshot.alertVolume == 37)
        #expect(snapshot.isMuted)
        #expect(snapshot.deviceID == 1)
        #expect(snapshot.deviceName == "测试扬声器")
        #expect(hardware.observedDevice == 1)
        backend.shutdown()
    }

    @Test func outputWriteReturnsReadbackAndPreservesMuteAndAlert() async throws {
        let script = VolumeScriptFake()
        script.isMuted = true
        script.quantizedOutput = 73
        let backend = makeBackend(script)
        let snapshot = try await backend.setOutputVolume(74.4, expectedDeviceID: 1)
        #expect(script.scripts == [AppleScriptSystemVolumeBackend.outputScript(74), AppleScriptSystemVolumeBackend.readScript])
        #expect(snapshot.outputVolume == 73)
        #expect(snapshot.alertVolume == 37)
        #expect(snapshot.isMuted)
        backend.shutdown()
    }

    @Test func alertWriteDoesNotChangeOutputOrMute() async throws {
        let script = VolumeScriptFake()
        let backend = makeBackend(script)
        let snapshot = try await backend.setAlertVolume(81.8)
        #expect(script.scripts.first == "set volume alert volume 82")
        #expect(snapshot.alertVolume == 82)
        #expect(snapshot.outputVolume == 60)
        #expect(!snapshot.isMuted)
        backend.shutdown()
    }

    @Test func staleDeviceAndUnsupportedControlNeverWrite() async throws {
        let script = VolumeScriptFake()
        let hardware = VolumeHardwareFake()
        let backend = makeBackend(script, hardware)
        await #expect(throws: SwitchFailure.self) {
            try await backend.setOutputVolume(80, expectedDeviceID: 2)
        }
        hardware.device.outputAvailability = .unsupported("设备没有音量控制")
        await #expect(throws: SwitchFailure.unsupported("设备没有音量控制")) {
            try await backend.setOutputVolume(80, expectedDeviceID: 1)
        }
        #expect(script.scripts.isEmpty)
        // Independent alert control remains usable on a fixed-volume route.
        #expect(try await backend.setAlertVolume(20).alertVolume == 20)
        backend.shutdown()
    }

    @Test func hotSwapBeforeWriteAndDuringReadRejectStaleResult() async throws {
        let script = VolumeScriptFake()
        let hardware = VolumeHardwareFake()
        let backend = makeBackend(script, hardware)
        hardware.deviceIDs = [1, 2]
        await #expect(throws: SwitchFailure.self) { try await backend.setOutputVolume(80, expectedDeviceID: 1) }
        #expect(script.scripts.isEmpty)
        hardware.deviceIDs = [1, 2]
        await #expect(throws: SwitchFailure.self) { try await backend.read() }
        #expect(script.scripts == [AppleScriptSystemVolumeBackend.readScript])
        backend.shutdown()
    }

    @Test func hotSwapAfterWriteDoesNotRetryOnReplacement() async throws {
        let script = VolumeScriptFake()
        let hardware = VolumeHardwareFake()
        let backend = makeBackend(script, hardware)
        hardware.deviceIDs = [1, 1, 2]
        await #expect(throws: SwitchFailure.self) { try await backend.setOutputVolume(80, expectedDeviceID: 1) }
        #expect(script.scripts == [AppleScriptSystemVolumeBackend.outputScript(80)])
        backend.shutdown()
    }

    @Test func writeAndMalformedReadbackFailuresAreNotSuccessfulSnapshots() async throws {
        let script = VolumeScriptFake()
        let backend = makeBackend(script)
        script.failure = .failed("脚本失败")
        await #expect(throws: SwitchFailure.failed("脚本失败")) { try await backend.setAlertVolume(80) }
        script.failure = nil
        script.readbackOverride = "60|broken|false"
        await #expect(throws: SwitchFailure.self) { try await backend.read() }
        backend.shutdown()
    }

    @Test func parserRejectsMissingOutOfRangeAndUnexpectedFields() throws {
        for value in ["", "60|30", "60|30|false|extra", "-1|50|false", "101|50|false", "40|120|false", "40|50|yes", "nan|50|false", "40.5|50|false"] {
            #expect(throws: SwitchFailure.self) { try AppleScriptSystemVolumeBackend.parseSettings(value) }
        }
        let parsed = try AppleScriptSystemVolumeBackend.parseSettings(" 0 | 100 | true\n")
        #expect(parsed.outputVolume == 0)
        #expect(parsed.alertVolume == 100)
        #expect(parsed.isMuted)
    }

    @Test func finiteInputIsClampedAndInvalidInputNeverExecutes() async throws {
        let script = VolumeScriptFake()
        let backend = makeBackend(script)
        await #expect(throws: SwitchFailure.self) { try await backend.setAlertVolume(.nan) }
        await #expect(throws: SwitchFailure.self) { try await backend.setOutputVolume(.infinity, expectedDeviceID: 1) }
        #expect(script.scripts.isEmpty)
        #expect(try await backend.setAlertVolume(500).alertVolume == 100)
        #expect(try await backend.setOutputVolume(-10, expectedDeviceID: 1).outputVolume == 0)
        backend.shutdown()
    }

    @Test func continuousOperationsSerializeWriteAndReadbackPairs() async throws {
        let script = VolumeScriptFake()
        script.pauseNextWrite = true
        let backend = makeBackend(script)
        let first = Task { try await backend.setOutputVolume(70, expectedDeviceID: 1) }
        while script.pausedWrite == nil { await Task.yield() }
        let second = Task { try await backend.setOutputVolume(90, expectedDeviceID: 1) }
        await Task.yield()
        #expect(script.scripts == [AppleScriptSystemVolumeBackend.outputScript(70)])
        script.pausedWrite?.resume()
        script.pausedWrite = nil
        #expect(try await first.value.outputVolume == 70)
        #expect(try await second.value.outputVolume == 90)
        #expect(script.scripts == [
            AppleScriptSystemVolumeBackend.outputScript(70), AppleScriptSystemVolumeBackend.readScript,
            AppleScriptSystemVolumeBackend.outputScript(90), AppleScriptSystemVolumeBackend.readScript
        ])
        backend.shutdown()
    }

    @Test func externalNotificationsAndShutdownReleaseObservation() async throws {
        let hardware = VolumeHardwareFake()
        let backend = makeBackend(VolumeScriptFake(), hardware)
        var notifications = 0
        backend.onChange = { notifications += 1 }
        hardware.onChange?()
        #expect(notifications == 1)
        backend.shutdown()
        #expect(hardware.didShutdown)
        #expect(hardware.onChange == nil)
        #expect(backend.onChange == nil)
        await #expect(throws: SwitchFailure.self) { try await backend.read() }
        await #expect(throws: SwitchFailure.self) { try await backend.setAlertVolume(50) }
    }

    private func makeBackend(_ script: VolumeScriptFake, _ hardware: VolumeHardwareFake = VolumeHardwareFake()) -> AppleScriptSystemVolumeBackend {
        AppleScriptSystemVolumeBackend(hardware: hardware, pollInterval: nil) { try await script.run($0) }
    }
}

@MainActor
private final class VolumeScriptFake {
    var output = 60
    var alert = 37
    var isMuted = false
    var scripts: [String] = []
    var failure: SwitchFailure?
    var quantizedOutput: Int?
    var readbackOverride: String?
    var pauseNextWrite = false
    var pausedWrite: CheckedContinuation<Void, Never>?

    func run(_ script: String) async throws -> String {
        scripts.append(script)
        if let failure { throw failure }
        if script == AppleScriptSystemVolumeBackend.readScript {
            return readbackOverride ?? "\(output)|\(alert)|\(isMuted)"
        }
        if pauseNextWrite {
            pauseNextWrite = false
            await withCheckedContinuation { pausedWrite = $0 }
        }
        let command = script.split(separator: "\n").last.map(String.init) ?? script
        let words = command.split(separator: " ")
        let value = words.count > 4 ? Int(words[4]) ?? -1 : -1
        if command.hasPrefix("set volume output volume ") {
            output = quantizedOutput ?? value
            // Matches the verified macOS behavior: omitted mute does unmute.
            if !command.contains("output muted preservedMute") { isMuted = false }
        }
        else if command.hasPrefix("set volume alert volume ") { alert = value }
        else { throw SwitchFailure.failed("意外的脚本") }
        return ""
    }
}

@MainActor
private final class VolumeHardwareFake: SystemVolumeHardware {
    var onChange: (@MainActor () -> Void)?
    var device = SystemVolumeDevice(id: 1, name: "测试扬声器")
    var deviceIDs: [AudioObjectID] = []
    var observedDevice: AudioObjectID?
    var didShutdown = false
    func currentDevice() throws -> SystemVolumeDevice {
        if !deviceIDs.isEmpty { device.id = deviceIDs.removeFirst() }
        return device
    }
    func observe(deviceID: AudioObjectID) throws { observedDevice = deviceID }
    func shutdown() { didShutdown = true; observedDevice = nil }
}
