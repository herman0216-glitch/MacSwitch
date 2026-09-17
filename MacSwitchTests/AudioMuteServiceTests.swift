import CoreAudio
import Testing
@testable import MacSwitch

@MainActor
struct AudioMuteServiceTests {
    @Test func readsActualDeviceAndCapability() async throws {
        let backend = MockAudioMuteBackend()
        backend.devices[1]?.muted = true
        backend.devices[1]?.isWritable = false
        let service = AudioMuteService(input: true, backend: backend)
        let state = try await service.read()
        #expect(service.id == .inputMute)
        #expect(state.isEnabled)
        #expect(state.detail == "设备一")
        #expect(state.availability == .unsupported("此设备的静音状态为只读，无法通过系统接口修改。"))
        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(false) }
        #expect(backend.writes.isEmpty)
    }

    @Test func missingDeviceOrMutePropertyIsUnsupported() async throws {
        let backend = MockAudioMuteBackend()
        let service = AudioMuteService(input: true, backend: backend)
        backend.currentDevice = kAudioObjectUnknown
        let absent = try await service.read()
        #expect(absent.availability == .unsupported("未找到默认输入设备。"))
        backend.currentDevice = 1
        backend.devices[1]?.muted = nil
        let unsupported = try await service.read()
        #expect(unsupported.availability == .unsupported("此输入设备未提供系统麦克风静音控制。"))
        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
        #expect(backend.writes.isEmpty)
    }

    @Test func disconnectedDeviceDoesNotWrite() async throws {
        let backend = MockAudioMuteBackend()
        backend.devices[1]?.isAlive = false
        let service = AudioMuteService(input: false, backend: backend)
        let state = try await service.read()
        #expect(state.availability == .unsupported("设备一 已断开，请连接可用的音频设备。"))
        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
        #expect(backend.writes.isEmpty)
    }

    @Test func writesThenReadsTheActualValue() async throws {
        let backend = MockAudioMuteBackend()
        let service = AudioMuteService(input: false, backend: backend)
        _ = try await service.read()
        let state = try await service.setEnabled(true)
        #expect(state.isEnabled)
        #expect(backend.writes.count == 1)
        #expect(backend.writes.first?.device == 1)
        #expect(backend.writes.first?.input == false)
        #expect(backend.deviceReads == 3)
    }

    @Test func switchingDefaultsReadsNewStateWithoutInheritingMute() async throws {
        let backend = MockAudioMuteBackend()
        backend.devices[1]?.muted = true
        let service = AudioMuteService(input: false, backend: backend)
        #expect(try await service.read().isEnabled)
        backend.currentDevice = 2
        let state = try await service.read()
        #expect(!state.isEnabled)
        #expect(state.detail == "设备二")
        #expect(backend.observedDevice == 2)
        #expect(backend.writes.isEmpty)
    }

    @Test func asynchronousHardwareWriteWaitsForRealReadback() async throws {
        let backend = MockAudioMuteBackend()
        backend.delayedWriteReads = 3
        let service = AudioMuteService(input: false, backend: backend)
        let state = try await service.setEnabled(true)
        #expect(state.isEnabled)
        #expect(backend.writes.count == 1)
        #expect(backend.deviceReads == 4)
    }

    @Test func defaultChangeDuringReadCannotPresentStaleSnapshot() async throws {
        let backend = MockAudioMuteBackend()
        backend.defaultResponses = [1, 2]
        let service = AudioMuteService(input: false, backend: backend)
        await #expect(throws: SwitchFailure.self) { try await service.read() }
        #expect(backend.writes.isEmpty)
    }

    @Test func stalePanelActionCannotMuteReplacementDevice() async throws {
        let backend = MockAudioMuteBackend()
        let service = AudioMuteService(input: false, backend: backend)
        _ = try await service.read()
        backend.currentDevice = 2
        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
        #expect(backend.writes.isEmpty)
        #expect(backend.devices[2]?.muted == false)
        #expect(backend.observedDevice == 2)
    }

    @Test func hotSwapImmediatelyBeforeWriteDoesNotWrite() async throws {
        let backend = MockAudioMuteBackend()
        let service = AudioMuteService(input: false, backend: backend)
        _ = try await service.read()
        backend.defaultResponses = [1, 2]
        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
        #expect(backend.writes.isEmpty)
    }

    @Test func hotSwapAfterWriteNeverRetriesOnReplacement() async throws {
        let backend = MockAudioMuteBackend()
        let service = AudioMuteService(input: false, backend: backend)
        _ = try await service.read()
        backend.defaultResponses = [1, 1, 2]
        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
        #expect(backend.writes.count == 1)
        #expect(backend.writes.first?.device == 1)
        #expect(backend.devices[2]?.muted == false)
    }

    @Test func writeErrorAndUnchangedReadbackAreFailures() async throws {
        let backend = MockAudioMuteBackend()
        let service = AudioMuteService(input: false, backend: backend)
        backend.writeError = .failed("模拟写入错误")
        await #expect(throws: SwitchFailure.failed("模拟写入错误")) { try await service.setEnabled(true) }
        #expect(backend.devices[1]?.muted == false)
        backend.writeError = nil
        backend.ignoreWrites = true
        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
        #expect(try await service.read().isEnabled == false)
    }

    @Test func readErrorDoesNotProduceSuccessfulSnapshot() async throws {
        let backend = MockAudioMuteBackend()
        let service = AudioMuteService(input: false, backend: backend)
        backend.readError = .failed("模拟读取错误")
        await #expect(throws: SwitchFailure.failed("模拟读取错误")) { try await service.read() }
        #expect(backend.writes.isEmpty)
    }

    @Test func externalNotificationsAndShutdown() async throws {
        let backend = MockAudioMuteBackend()
        let service = AudioMuteService(input: false, backend: backend)
        var notifications = 0
        service.onChange = { notifications += 1 }
        _ = try await service.read()
        backend.onChange?()
        #expect(notifications == 1)
        service.shutdown()
        #expect(backend.didShutdown)
        #expect(backend.onChange == nil)
        #expect(service.onChange == nil)
        await #expect(throws: SwitchFailure.self) { try await service.read() }
    }
}

@MainActor
private final class MockAudioMuteBackend: AudioMuteBackend {
    struct Write {
        var device: AudioObjectID
        var input: Bool
        var enabled: Bool
    }
    var onChange: (@MainActor () -> Void)?
    var currentDevice: AudioObjectID = 1
    var defaultResponses: [AudioObjectID] = []
    var devices: [AudioObjectID: AudioMuteDeviceState] = [
        1: AudioMuteDeviceState(name: "设备一", isAlive: true, muted: false, isWritable: true),
        2: AudioMuteDeviceState(name: "设备二", isAlive: true, muted: false, isWritable: true)
    ]
    var observedDevice: AudioObjectID?
    var writes: [Write] = []
    var readError: SwitchFailure?
    var writeError: SwitchFailure?
    var ignoreWrites = false
    var delayedWriteReads = 0
    private var pendingWrite: Write?
    var deviceReads = 0
    var didShutdown = false

    func defaultDevice(input: Bool) throws -> AudioObjectID {
        if !defaultResponses.isEmpty { currentDevice = defaultResponses.removeFirst() }
        return currentDevice
    }
    func readDevice(_ device: AudioObjectID, input: Bool) throws -> AudioMuteDeviceState {
        deviceReads += 1
        if let readError { throw readError }
        if let pendingWrite {
            delayedWriteReads -= 1
            if delayedWriteReads <= 0 {
                devices[pendingWrite.device]?.muted = pendingWrite.enabled
                self.pendingWrite = nil
            }
        }
        guard let state = devices[device] else { throw SwitchFailure.failed("设备已断开") }
        return state
    }
    func setMute(_ enabled: Bool, device: AudioObjectID, input: Bool) throws {
        if let writeError { throw writeError }
        let write = Write(device: device, input: input, enabled: enabled)
        writes.append(write)
        if !ignoreWrites {
            if delayedWriteReads > 0 { pendingWrite = write }
            else { devices[device]?.muted = enabled }
        }
    }
    func observe(device: AudioObjectID?, input: Bool) throws { observedDevice = device }
    func shutdown() { didShutdown = true; observedDevice = nil }
}
