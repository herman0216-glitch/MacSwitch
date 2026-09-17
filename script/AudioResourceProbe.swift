import CoreAudio
import Foundation

/// Read-only process/route observation; compile with Services/AudioHAL.swift.
@main
enum AudioResourceProbe {
    static func main() throws {
        let device = try AudioHAL.defaultOutputDevice()
        let input = try AudioHAL.value(AudioObjectID(kAudioObjectSystemObject),
                                       selector: kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(0))
        let prefixes = ["local.herman.MacSwitch"] + CommandLine.arguments.dropFirst()
        let processes = try AudioHAL.objectIDs(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
        var rows: [[String: Any]] = []
        for process in processes {
            let bundle = (try? AudioHAL.string(process, selector: kAudioProcessPropertyBundleID)) ?? ""
            guard prefixes.contains(where: { bundle.hasPrefix($0) }) else { continue }
            rows.append([
                "bundle": bundle,
                "pid": try AudioHAL.value(process, selector: kAudioProcessPropertyPID, initial: pid_t(0)),
                "runningOutput": try AudioHAL.value(process, selector: kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) != 0,
                "outputDevices": (try? AudioHAL.objectIDs(process, selector: kAudioProcessPropertyDevices, scope: kAudioDevicePropertyScopeOutput)) ?? []
            ])
        }
        let devices = try AudioHAL.objectIDs(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices)
        let outputDevices: [[String: Any]] = devices.compactMap { id in
            guard let streams = try? AudioHAL.objectIDs(id, selector: kAudioDevicePropertyStreams,
                                                        scope: kAudioDevicePropertyScopeOutput), !streams.isEmpty else { return nil }
            return [
                "id": id,
                "name": (try? AudioHAL.string(id, selector: kAudioObjectPropertyName)) ?? "Unknown",
                "sampleRate": (try? AudioHAL.value(id, selector: kAudioDevicePropertyNominalSampleRate, initial: Float64(0))) ?? 0,
                "outputStreams": streams.count,
                "outputBufferChannels": (try? AudioHAL.bufferChannels(device: id, scope: kAudioDevicePropertyScopeOutput)) ?? [],
                "supportedFormat": (try? AudioHAL.outputDescriptor(for: id)) != nil
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: ["date": Date().ISO8601Format(),
            "defaultOutput": device, "defaultInput": input,
            "inputDeviceName": (try? AudioHAL.string(input, selector: kAudioObjectPropertyName)) ?? "Unknown",
            "processes": rows, "outputDevices": outputDevices], options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
