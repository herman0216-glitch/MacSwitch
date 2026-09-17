import CoreAudio
import Foundation

struct AudioHALError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

struct AudioPCMFormat: Equatable, Sendable {
    let sampleRate: Double
    let channels: UInt32
    let isInterleaved: Bool
    let bytesPerFrame: UInt32

    init(_ format: AudioStreamBasicDescription) throws {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mBitsPerChannel == 32,
              (1...2).contains(format.mChannelsPerFrame),
              format.mSampleRate.isFinite, format.mSampleRate > 0,
              format.mFramesPerPacket == 1 else {
            throw AudioHALError(message: "当前设备不是受支持的单声道／立体声 Float32 PCM，保留原声。")
        }
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        guard format.mBytesPerFrame == 4 * (interleaved ? format.mChannelsPerFrame : 1) else {
            throw AudioHALError(message: "当前 PCM 缓冲区布局不受支持，保留原声。")
        }
        sampleRate = format.mSampleRate
        channels = format.mChannelsPerFrame
        isInterleaved = interleaved
        bytesPerFrame = format.mBytesPerFrame
    }
}

struct AudioOutputDescriptor: Equatable, Sendable {
    let deviceID: AudioObjectID
    let uid: String
    let name: String
    let streamID: AudioObjectID
    let streamIndex: UInt
    let format: AudioPCMFormat
}

enum AudioHAL {
    static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw AudioHALError(message: "\(operation)失败（Core Audio \(status)）。") }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func value<T: BitwiseCopyable>(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                                         initial: T, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                         element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> T {
        var property = address(selector, scope: scope, element: element)
        var size = UInt32(MemoryLayout<T>.size)
        var result = initial
        try withUnsafeMutablePointer(to: &result) {
            try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0), "读取音频属性")
        }
        guard size == MemoryLayout<T>.size else { throw AudioHALError(message: "音频属性大小发生变化。") }
        return result
    }

    static func objectIDs(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [AudioObjectID] {
        var property = address(selector, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size), "读取音频对象列表")
        guard size > 0 else { return [] }
        var result = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        try result.withUnsafeMutableBytes {
            try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, $0.baseAddress!), "读取音频对象列表")
        }
        return Array(result.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }

    static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var property = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        try check(AudioObjectGetPropertyData(object, &property, 0, nil, &size, &result), "读取音频名称")
        guard let result else { throw AudioHALError(message: "音频名称不可用。") }
        return result.takeRetainedValue() as String
    }

    static func defaultOutputDevice() throws -> AudioObjectID {
        let device = try value(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
        guard device != kAudioObjectUnknown else { throw AudioHALError(message: "当前没有默认输出设备。") }
        return device
    }

    static func outputDescriptor(for device: AudioObjectID) throws -> AudioOutputDescriptor {
        let streams = try objectIDs(device, selector: kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        guard streams.count == 1, let stream = streams.first else {
            throw AudioHALError(message: "当前设备有多个输出流或没有输出流，保留原声。")
        }
        let format = try streamFormat(stream)
        return AudioOutputDescriptor(deviceID: device,
                                     uid: try string(device, selector: kAudioDevicePropertyDeviceUID),
                                     name: try string(device, selector: kAudioObjectPropertyName),
                                     streamID: stream, streamIndex: 0, format: format)
    }

    static func streamFormat(_ stream: AudioObjectID) throws -> AudioPCMFormat {
        try AudioPCMFormat(value(stream, selector: kAudioStreamPropertyVirtualFormat, initial: AudioStreamBasicDescription()))
    }

    static func volumeDecibels(device: AudioObjectID, scalar: Float) -> Float? {
        if let result = try? value(device, selector: kAudioDevicePropertyVolumeScalarToDecibels,
                                   initial: scalar, scope: kAudioDevicePropertyScopeOutput), result.isFinite { return result }
        // A single common curve is safe only when both channel controls agree.
        guard let left = try? value(device, selector: kAudioDevicePropertyVolumeScalarToDecibels,
                                    initial: scalar, scope: kAudioDevicePropertyScopeOutput, element: 1),
              let right = try? value(device, selector: kAudioDevicePropertyVolumeScalarToDecibels,
                                     initial: scalar, scope: kAudioDevicePropertyScopeOutput, element: 2),
              left.isFinite, right.isFinite, abs(left - right) < 0.01 else { return nil }
        return left
    }

    static func bufferChannels(device: AudioObjectID, scope: AudioObjectPropertyScope) throws -> [UInt32] {
        var property = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(device, &property, 0, nil, &size), "读取音频缓冲区布局")
        guard size >= MemoryLayout<AudioBufferList>.size else { return [] }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        try check(AudioObjectGetPropertyData(device, &property, 0, nil, &size, memory), "读取音频缓冲区布局")
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).map(\.mNumberChannels)
    }
}
