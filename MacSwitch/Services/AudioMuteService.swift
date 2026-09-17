import CoreAudio
import Foundation

/// A snapshot of the device itself. A missing master-mute property is represented
/// by `muted == nil`; changing stream volume is deliberately not used as a fallback.
struct AudioMuteDeviceState {
    var name: String
    var isAlive: Bool
    var muted: Bool?
    var isWritable: Bool
}

@MainActor
protocol AudioMuteBackend: AnyObject {
    var onChange: (@MainActor () -> Void)? { get set }
    func defaultDevice(input: Bool) throws -> AudioObjectID
    func readDevice(_ device: AudioObjectID, input: Bool) throws -> AudioMuteDeviceState
    func setMute(_ enabled: Bool, device: AudioObjectID, input: Bool) throws
    func observe(device: AudioObjectID?, input: Bool) throws
    func shutdown()
}

@MainActor
final class AudioMuteService: SwitchService {
    let id: FeatureID
    var onChange: (@MainActor () -> Void)?

    private let input: Bool
    private let backend: any AudioMuteBackend
    private var displayedDevice: AudioObjectID?
    private var hasRead = false
    private var stopped = false

    init(input: Bool, backend: (any AudioMuteBackend)? = nil) {
        self.input = input
        self.id = input ? .inputMute : .outputMute
        self.backend = backend ?? CoreAudioMuteBackend()
        self.backend.onChange = { [weak self] in self?.onChange?() }
    }

    func read() async throws -> SwitchSnapshot {
        try readCurrentSnapshot()
    }

    func setEnabled(_ enabled: Bool) async throws -> SwitchSnapshot {
        try ensureRunning()
        let device = try backend.defaultDevice(input: input)
        // A click was made against the device shown in the panel. If it has
        // changed, refresh and require another action instead of carrying that
        // device's intended mute value across to the replacement device.
        if hasRead, displayedDevice != knownDevice(device) {
            throw defaultDeviceChanged()
        }
        guard device != kAudioObjectUnknown else {
            throw SwitchFailure.unsupported(noDeviceReason)
        }

        try backend.observe(device: device, input: input)
        let before = try backend.readDevice(device, input: input)
        if let reason = unsupportedReason(before) {
            throw SwitchFailure.unsupported(reason)
        }
        // CoreAudio has no atomic "write only if still default" operation.
        // Check immediately before and after the write; never retry on a new ID.
        guard try backend.defaultDevice(input: input) == device else {
            throw defaultDeviceChanged()
        }
        try backend.setMute(enabled, device: device, input: input)
        // HAL property changes may complete asynchronously. Poll briefly without
        // blocking the main actor, while guarding the default ID on every pass.
        for attempt in 0..<20 {
            try ensureRunning()
            guard try backend.defaultDevice(input: input) == device else {
                throw defaultDeviceChanged()
            }
            let after = try backend.readDevice(device, input: input)
            if let reason = unsupportedReason(after) {
                throw SwitchFailure.unsupported(reason)
            }
            guard try backend.defaultDevice(input: input) == device else {
                throw defaultDeviceChanged()
            }
            if after.muted == enabled {
                displayedDevice = device
                hasRead = true
                return snapshot(after)
            }
            if attempt < 19 { try await Task.sleep(for: .milliseconds(25)) }
        }
        throw SwitchFailure.failed("\(before.name) 未应用静音设置，已保留设备的实际状态。")
    }

    func shutdown() {
        stopped = true
        backend.onChange = nil
        backend.shutdown()
        onChange = nil
    }

    private var noDeviceReason: String {
        input ? "未找到默认输入设备。" : "未找到默认输出设备。"
    }

    private func knownDevice(_ device: AudioObjectID) -> AudioObjectID? {
        device == kAudioObjectUnknown ? nil : device
    }

    private func ensureRunning() throws {
        guard !stopped else { throw SwitchFailure.failed("音频服务已停止。") }
    }

    private func readCurrentSnapshot() throws -> SwitchSnapshot {
        try ensureRunning()
        let device = try backend.defaultDevice(input: input)
        try backend.observe(device: knownDevice(device), input: input)
        guard device != kAudioObjectUnknown else {
            displayedDevice = nil
            hasRead = true
            return SwitchSnapshot(isEnabled: false, availability: .unsupported(noDeviceReason))
        }
        let state = try backend.readDevice(device, input: input)
        // Avoid presenting a device as current when it disappeared during reads.
        guard try backend.defaultDevice(input: input) == device else {
            onChange?()
            throw SwitchFailure.failed("默认音频设备正在更换，请稍后重试。")
        }
        displayedDevice = device
        hasRead = true
        return snapshot(state)
    }

    private func defaultDeviceChanged() -> SwitchFailure {
        // Best-effort refresh also rebinds listeners. Never perform a write here.
        _ = try? readCurrentSnapshot()
        onChange?()
        return .failed("默认音频设备已更换，请等待状态刷新后重新操作。")
    }

    private func snapshot(_ state: AudioMuteDeviceState) -> SwitchSnapshot {
        SwitchSnapshot(
            isEnabled: state.muted ?? false,
            detail: state.name,
            availability: unsupportedReason(state).map(SwitchAvailability.unsupported) ?? .available
        )
    }

    private func unsupportedReason(_ state: AudioMuteDeviceState) -> String? {
        if !state.isAlive { return "\(state.name) 已断开，请连接可用的音频设备。" }
        if state.muted == nil {
            return input
                ? "此输入设备未提供系统麦克风静音控制。"
                : "此输出设备未提供系统声音静音控制。"
        }
        if !state.isWritable { return "此设备的静音状态为只读，无法通过系统接口修改。" }
        return nil
    }
}

@MainActor
final class CoreAudioMuteBackend: AudioMuteBackend {
    var onChange: (@MainActor () -> Void)?

    private struct Subscription {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var subscriptions: [Subscription] = []
    private var observedDevice: AudioObjectID?

    func defaultDevice(input: Bool) throws -> AudioObjectID {
        var address = defaultAddress(input: input)
        return try uint32(AudioObjectID(kAudioObjectSystemObject), address: &address, operation: "读取默认音频设备")
    }

    func readDevice(_ device: AudioObjectID, input: Bool) throws -> AudioMuteDeviceState {
        var aliveAddress = address(kAudioDevicePropertyDeviceIsAlive)
        let alive = try uint32(device, address: &aliveAddress, operation: "检查音频设备连接") != 0
        guard alive else {
            return AudioMuteDeviceState(name: "音频设备", isAlive: false, muted: nil, isWritable: false)
        }
        var nameAddress = address(kAudioObjectPropertyName)
        // The HAL transfers a retained CFString to the caller for this property.
        var nameReference: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &nameSize, &nameReference), operation: "读取音频设备名称")
        let name = nameReference?.takeRetainedValue() as String? ?? "音频设备"

        var muteAddress = address(kAudioDevicePropertyMute, input: input)
        guard AudioObjectHasProperty(device, &muteAddress) else {
            return AudioMuteDeviceState(name: name, isAlive: true, muted: nil, isWritable: false)
        }
        var writable: DarwinBoolean = false
        try check(AudioObjectIsPropertySettable(device, &muteAddress, &writable), operation: "检查音频静音控制能力")
        let muted = try uint32(device, address: &muteAddress, operation: "读取音频静音状态") != 0
        return AudioMuteDeviceState(name: name, isAlive: true, muted: muted, isWritable: writable.boolValue)
    }

    func setMute(_ enabled: Bool, device: AudioObjectID, input: Bool) throws {
        var muteAddress = address(kAudioDevicePropertyMute, input: input)
        guard AudioObjectHasProperty(device, &muteAddress) else {
            throw SwitchFailure.unsupported("此音频设备未提供系统静音控制。")
        }
        var writable: DarwinBoolean = false
        try check(AudioObjectIsPropertySettable(device, &muteAddress, &writable), operation: "检查音频静音控制能力")
        guard writable.boolValue else { throw SwitchFailure.unsupported("此设备的静音状态为只读。") }
        var value: UInt32 = enabled ? 1 : 0
        try check(AudioObjectSetPropertyData(device, &muteAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value), operation: "设置音频静音状态")
    }

    func observe(device: AudioObjectID?, input: Bool) throws {
        let system = AudioObjectID(kAudioObjectSystemObject)
        if !subscriptions.contains(where: { $0.object == system }) {
            try addListener(object: system, address: defaultAddress(input: input))
        }
        guard device != observedDevice else { return }
        removeDeviceListeners()
        guard let device else { return }
        do {
            for property in [
                address(kAudioDevicePropertyMute, input: input),
                address(kAudioDevicePropertyDeviceIsAlive),
                address(kAudioObjectPropertyName),
                address(kAudioDevicePropertyDeviceHasChanged)
            ] {
                var candidate = property
                if AudioObjectHasProperty(device, &candidate) {
                    try addListener(object: device, address: candidate)
                }
            }
            observedDevice = device
        } catch {
            removeDeviceListeners()
            throw error
        }
    }

    func shutdown() {
        for var subscription in subscriptions {
            AudioObjectRemovePropertyListenerBlock(subscription.object, &subscription.address, .main, subscription.block)
        }
        subscriptions.removeAll()
        observedDevice = nil
        onChange = nil
    }

    private func addListener(object: AudioObjectID, address: AudioObjectPropertyAddress) throws {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.onChange?() }
        }
        try check(AudioObjectAddPropertyListenerBlock(object, &address, .main, block), operation: "监听音频设备变化")
        subscriptions.append(Subscription(object: object, address: address, block: block))
    }

    private func removeDeviceListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for var subscription in subscriptions where subscription.object != system {
            AudioObjectRemovePropertyListenerBlock(subscription.object, &subscription.address, .main, subscription.block)
        }
        subscriptions.removeAll { $0.object != system }
        observedDevice = nil
    }

    private func defaultAddress(input: Bool) -> AudioObjectPropertyAddress {
        address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func address(_ selector: AudioObjectPropertySelector, input: Bool? = nil) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: input.map { $0 ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput } ?? kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func uint32(_ object: AudioObjectID, address: inout AudioObjectPropertyAddress, operation: String) throws -> UInt32 {
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), operation: operation)
        return value
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            if status == kAudioHardwareBadDeviceError || status == kAudioHardwareBadObjectError {
                throw SwitchFailure.failed("音频设备已断开或发生变化，请重新连接后重试。（\(status)）")
            }
            throw SwitchFailure.failed("\(operation)失败，请稍后重试。（\(status)）")
        }
    }
}
