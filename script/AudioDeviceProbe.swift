import CoreAudio
import Foundation

/// Creates one named temporary aggregate, switches defaults, then restores both
/// original device IDs and destroys only the aggregate created by this process.
@main
struct AudioDeviceProbe {
    @MainActor static func main() async throws {
        let backend = CoreAudioMuteBackend()
        let output = try backend.defaultDevice(input: false)
        let input = try backend.defaultDevice(input: true)
        let uids = try Set([uid(output), uid(input)])
        let specification: [String: Any] = [
            kAudioAggregateDeviceUIDKey: "local.herman.MacSwitch.probe.\(UUID())",
            kAudioAggregateDeviceNameKey: "MacSwitch Temporary Test Device",
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceSubDeviceListKey: uids.map { [kAudioSubDeviceUIDKey: $0] },
            kAudioAggregateDeviceMainSubDeviceKey: try uid(output)
        ]
        var aggregate: AudioObjectID = 0
        try check(AudioHardwareCreateAggregateDevice(specification as CFDictionary, &aggregate))
        var temporaryIsAlive = true
        defer {
            do { try setDefault(output, input: false) }
            catch { print("OUTPUT RESTORE FAILED: \(error)") }
            do { try setDefault(input, input: true) }
            catch { print("INPUT RESTORE FAILED: \(error)") }
            if temporaryIsAlive {
                let result = AudioHardwareDestroyAggregateDevice(aggregate)
                print("destroy temporary device=\(aggregate), status=\(result)")
            }
        }
        try await Task.sleep(for: .seconds(1))
        try setDefault(aggregate, input: false)
        try setDefault(aggregate, input: true)
        print("temporary device=\(aggregate); original output=\(output), input=\(input)")
        for isInput in [false, true] {
            let service = AudioMuteService(input: isInput)
            print("\(service.id.rawValue): \(try await service.read())")
            service.shutdown()
        }
        fflush(stdout)
        try await Task.sleep(for: .seconds(25))
        // Destroy while current to exercise device disappearance and OS fallback.
        try check(AudioHardwareDestroyAggregateDevice(aggregate))
        temporaryIsAlive = false
        print("device disconnected")
        try await Task.sleep(for: .seconds(2))
        try setDefault(output, input: false)
        try setDefault(input, input: true)
        print("restored original defaults")
    }

    static func uid(_ device: AudioObjectID) throws -> String {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ref))
        guard let value = ref?.takeRetainedValue() else { throw SwitchFailure.failed("Missing audio device UID") }
        return value as String
    }

    static func setDefault(_ device: AudioObjectID, input: Bool) throws {
        var address = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value = device
        try check(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value))
    }

    static func check(_ status: OSStatus) throws {
        if status != noErr { throw SwitchFailure.failed("CoreAudio status \(status)") }
    }
}
