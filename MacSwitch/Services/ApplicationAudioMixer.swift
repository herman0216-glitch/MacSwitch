import CoreAudio
import Foundation
import Synchronization

struct ApplicationAudioMixerStatus: Equatable, Sendable {
    let isRunning: Bool
    let message: String?
    let hasReceivedAudio: Bool
    let hasReceivedCallbacks: Bool
    let isLimiting: Bool
    let inputPeak: Float
    let outputPeak: Float
    let callbackCount: UInt64
    var requiresCleanup: Bool = false
}

/// Own one instance per application. Control operations stay on the main actor;
/// Core Audio's callback touches only its retained render context and atomics.
@MainActor
final class ApplicationAudioMixer {
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var contextPointer: UnsafeMutableRawPointer?
    private var renderContext: ApplicationAudioRenderContext?
    private var output: AudioOutputDescriptor?
    private var processObjectIDs: [AudioObjectID] = []
    private var isStarted = false
    private var lastSequence: UInt64 = 0
    private var lastCallbackDate = Date()
    private var failure: String?
    private var requestedGain = AudioGainResult(linearGain: 1, isAmplificationLimited: false, usesApproximateCurve: false)
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    var status: ApplicationAudioMixerStatus {
        let count = renderContext?.sequence.load(ordering: .relaxed) ?? 0
        return ApplicationAudioMixerStatus(
            isRunning: failure == nil && isStarted && renderContext != nil,
            message: failure,
            hasReceivedAudio: renderContext?.hasReceivedAudio.load(ordering: .relaxed) ?? false,
            hasReceivedCallbacks: count > 0,
            isLimiting: requestedGain.isAmplificationLimited || (renderContext?.peakLimited.load(ordering: .relaxed) ?? false),
            inputPeak: Float(bitPattern: renderContext?.inputPeak.load(ordering: .relaxed) ?? 0),
            outputPeak: Float(bitPattern: renderContext?.outputPeak.load(ordering: .relaxed) ?? 0),
            callbackCount: count,
            requiresCleanup: (failure != nil || !isStarted) && (tapID != 0 || aggregateID != 0 || ioProc != nil)
        )
    }

    isolated deinit { stop() }

    func start(application: DiscoveredAudioApplication, outputDevice: AudioObjectID, gain: AudioGainResult) throws {
        stop()
        guard tapID == 0, aggregateID == 0, ioProc == nil, contextPointer == nil else {
            throw AudioHALError(message: failure ?? "旧音频资源尚未释放，暂不能开始新的接管。")
        }
        failure = nil
        if let reason = application.unsupportedReason { throw AudioHALError(message: reason) }
        guard !application.processObjectIDs.isEmpty else { throw AudioHALError(message: "应用没有可接管的音频进程。") }
        let descriptor = try AudioHAL.outputDescriptor(for: outputDevice)
        guard try AudioHAL.defaultOutputDevice() == outputDevice else {
            throw AudioHALError(message: "默认输出设备已经变化，保留原声。")
        }
        for process in application.processObjectIDs {
            let routes = try AudioHAL.objectIDs(process, selector: kAudioProcessPropertyDevices,
                                               scope: kAudioDevicePropertyScopeOutput)
            guard routes == [outputDevice] else { throw AudioHALError(message: "应用输出路由已经变化，保留原声。") }
        }
        do {
            let description = CATapDescription(processes: application.processObjectIDs,
                                               deviceUID: descriptor.uid, stream: descriptor.streamIndex)
            description.name = "MacSwitch · \(application.name)"
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            try AudioHAL.check(AudioHardwareCreateProcessTap(description, &tapID), "创建应用音频接管")
            let tapFormat = try AudioPCMFormat(AudioHAL.value(tapID, selector: kAudioTapPropertyFormat,
                                                               initial: AudioStreamBasicDescription()))
            guard tapFormat.channels == descriptor.format.channels,
                  tapFormat.sampleRate == descriptor.format.sampleRate else {
                throw AudioHALError(message: "应用音频格式与输出设备不一致，保留原声。")
            }
            let tapUID = try AudioHAL.string(tapID, selector: kAudioTapPropertyUID)
            let specification: [String: Any] = [
                kAudioAggregateDeviceNameKey: "MacSwitch · \(application.name)",
                kAudioAggregateDeviceUIDKey: "local.herman.MacSwitch.audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceMainSubDeviceKey: descriptor.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[
                    kAudioSubDeviceUIDKey: descriptor.uid,
                    kAudioSubDeviceInputChannelsKey: 0,
                    kAudioSubDeviceOutputChannelsKey: descriptor.format.channels
                ]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]],
                kAudioAggregateDeviceTapAutoStartKey: false
            ]
            try AudioHAL.check(AudioHardwareCreateAggregateDevice(specification as CFDictionary, &aggregateID), "创建私有音频设备")
            let inputStreams = try AudioHAL.objectIDs(aggregateID, selector: kAudioDevicePropertyStreams,
                                                       scope: kAudioDevicePropertyScopeInput)
            let outputStreams = try AudioHAL.objectIDs(aggregateID, selector: kAudioDevicePropertyStreams,
                                                        scope: kAudioDevicePropertyScopeOutput)
            // The physical output's input channels must be absent: never read or relay a microphone.
            guard inputStreams.count == 1, outputStreams.count == 1,
                  let inputStream = inputStreams.first, let outputStream = outputStreams.first else {
                throw AudioHALError(message: "无法隔离应用音频与设备输入，保留原声。")
            }
            let inputFormat = try AudioHAL.streamFormat(inputStream)
            let outputFormat = try AudioHAL.streamFormat(outputStream)
            guard inputFormat.channels == tapFormat.channels,
                  outputFormat.channels == descriptor.format.channels,
                  inputFormat.sampleRate == outputFormat.sampleRate,
                  outputFormat.sampleRate == descriptor.format.sampleRate else {
                throw AudioHALError(message: "私有音频设备的流格式不匹配，保留原声。")
            }
            let inputChannels = try AudioHAL.bufferChannels(device: aggregateID, scope: kAudioDevicePropertyScopeInput)
            let outputChannels = try AudioHAL.bufferChannels(device: aggregateID, scope: kAudioDevicePropertyScopeOutput)
            guard inputChannels == Self.expectedBuffers(inputFormat),
                  outputChannels == Self.expectedBuffers(outputFormat) else {
                throw AudioHALError(message: "私有音频设备的缓冲区映射不受支持，保留原声。")
            }
            let context = ApplicationAudioRenderContext(input: inputFormat, output: outputFormat, initialGain: gain.linearGain)
            renderContext = context
            contextPointer = Unmanaged.passRetained(context).toOpaque()
            try AudioHAL.check(AudioDeviceCreateIOProcID(aggregateID, applicationAudioIOProc,
                                                         contextPointer, &ioProc), "建立应用音频回调")
            guard let ioProc else { throw AudioHALError(message: "应用音频回调不可用。") }
            // This is the public system-audio permission request point. Info.plist supplies NSAudioCaptureUsageDescription.
            try AudioHAL.check(AudioDeviceStart(aggregateID, ioProc), "开始应用音频处理（请确认系统音频录制权限）")
            isStarted = true
            output = descriptor
            processObjectIDs = application.processObjectIDs
            lastCallbackDate = Date()
            lastSequence = 0
            updateGain(gain)
            installRouteListeners(descriptor)
        } catch {
            stop()
            failure = [error.localizedDescription, failure].compactMap { $0 }.joined(separator: " ")
            throw error
        }
    }

    func updateGain(_ result: AudioGainResult) {
        requestedGain = result
        let gain = min(pow(10, AudioGain.maximumBoostDecibels / 20), max(0, result.linearGain.isFinite ? result.linearGain : 0))
        renderContext?.targetGain.store(gain.bitPattern, ordering: .relaxed)
    }

    /// Call periodically even while the menu is closed. Route listeners also call this immediately.
    @discardableResult
    func validateRouteAndHealth() -> String? {
        guard let output, let renderContext else { return failure }
        let reason: String?
        if (try? AudioHAL.defaultOutputDevice()) != output.deviceID {
            reason = "默认输出设备已变化，已停止接管并恢复原声。"
        } else if (try? AudioHAL.outputDescriptor(for: output.deviceID)) != output {
            reason = "输出设备或通话音频格式已变化，已停止接管并恢复原声。"
        } else if processObjectIDs.contains(where: {
            (try? AudioHAL.objectIDs($0, selector: kAudioProcessPropertyDevices,
                                     scope: kAudioDevicePropertyScopeOutput)) != [output.deviceID]
        }) {
            reason = "应用输出路由已变化，已停止接管并恢复原声。"
        } else if renderContext.fault.load(ordering: .relaxed) != 0 {
            reason = "音频缓冲区布局发生变化，已停止接管并恢复原声。"
        } else {
            let sequence = renderContext.sequence.load(ordering: .relaxed)
            if sequence != lastSequence {
                lastSequence = sequence
                lastCallbackDate = Date()
                return nil
            }
            // DeviceStart success alone does not prove that TCC allowed actual audio callbacks.
            reason = Date().timeIntervalSince(lastCallbackDate) > 2
                ? "未收到音频回调；请检查系统音频录制权限。已停止接管并恢复原声。" : nil
        }
        if let reason {
            stop()
            failure = [reason, failure].compactMap { $0 }.joined(separator: " ")
        }
        return reason
    }

    func stop() {
        for (object, property, listener) in listeners {
            var address = property
            AudioObjectRemovePropertyListenerBlock(object, &address, .main, listener)
        }
        listeners.removeAll()
        var cleanupErrors: [String] = []
        if let ioProc, aggregateID != 0 {
            let stopped = AudioDeviceStop(aggregateID, ioProc)
            let destroyed = AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            if stopped == noErr || destroyed == noErr { isStarted = false }
            if destroyed == noErr { self.ioProc = nil }
            else { cleanupErrors.append("释放回调 \(stopped)/\(destroyed)") }
        }
        if aggregateID != 0 {
            let destroyed = AudioHardwareDestroyAggregateDevice(aggregateID)
            if destroyed == noErr {
                aggregateID = 0
                ioProc = nil
                isStarted = false
            }
            else { cleanupErrors.append("释放私有设备 \(destroyed)") }
        }
        if tapID != 0 {
            let destroyed = AudioHardwareDestroyProcessTap(tapID)
            if destroyed != noErr { cleanupErrors.append("释放音频接管 \(destroyed)") }
            else { tapID = 0 }
        }
        if let contextPointer, ioProc == nil {
            Unmanaged<ApplicationAudioRenderContext>.fromOpaque(contextPointer).release()
            self.contextPointer = nil
            renderContext = nil
        }
        // Retain every failed HAL handle and its RT context so a subsequent stop can retry safely.
        output = nil
        processObjectIDs = []
        if aggregateID == 0 && tapID == 0 && ioProc == nil { failure = nil }
        else { failure = "音频恢复未能完全确认，将重试释放：" + cleanupErrors.joined(separator: "；") }
    }

    private static func expectedBuffers(_ format: AudioPCMFormat) -> [UInt32] {
        format.isInterleaved ? [format.channels] : Array(repeating: 1, count: Int(format.channels))
    }

    private func installRouteListeners(_ output: AudioOutputDescriptor) {
        let properties: [(AudioObjectID, AudioObjectPropertyAddress)] = [
            (AudioObjectID(kAudioObjectSystemObject), AudioHAL.address(kAudioHardwarePropertyDefaultOutputDevice)),
            (output.deviceID, AudioHAL.address(kAudioDevicePropertyDeviceIsAlive)),
            (output.streamID, AudioHAL.address(kAudioStreamPropertyVirtualFormat))
        ]
        for (object, property) in properties {
            var address = property
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.validateRouteAndHealth() }
            }
            if AudioObjectAddPropertyListenerBlock(object, &address, .main, listener) == noErr {
                listeners.append((object, property, listener))
            }
        }
    }
}

/// Only `targetGain`, counters and flags cross threads. All other mutable values belong to the single HAL callback.
final class ApplicationAudioRenderContext: @unchecked Sendable {
    let targetGain: Atomic<UInt32>
    let sequence = Atomic<UInt64>(0)
    let fault = Atomic<UInt32>(0)
    let peakLimited = Atomic<Bool>(false)
    let hasReceivedAudio = Atomic<Bool>(false)
    let inputPeak = Atomic<UInt32>(0)
    let outputPeak = Atomic<UInt32>(0)
    private let inputFormat: AudioPCMFormat
    private let outputFormat: AudioPCMFormat
    private let smoothing: Float
    private let limiterRelease: Float
    private var currentGain: Float
    private var limiterGain: Float = 1

    init(input: AudioPCMFormat, output: AudioPCMFormat, initialGain: Float) {
        inputFormat = input
        outputFormat = output
        let gain = max(0, initialGain.isFinite ? initialGain : 0)
        currentGain = gain
        targetGain = Atomic(gain.bitPattern)
        smoothing = 1 - exp(-1 / Float(0.01 * output.sampleRate))
        limiterRelease = 1 - exp(-1 / Float(0.1 * output.sampleRate))
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        // Also initialize explicitly so a format failure can never return stale samples.
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        let inputCount = inputFormat.isInterleaved ? 1 : Int(inputFormat.channels)
        let outputCount = outputFormat.isInterleaved ? 1 : Int(outputFormat.channels)
        guard inputs.count == inputCount, outputs.count == outputCount,
              let first = inputs.first, inputFormat.bytesPerFrame > 0,
              first.mDataByteSize % inputFormat.bytesPerFrame == 0 else {
            fault.store(1, ordering: .relaxed)
            return
        }
        let frames = Int(first.mDataByteSize / inputFormat.bytesPerFrame)
        for index in 0..<inputCount {
            guard inputs[index].mData != nil,
                  inputs[index].mNumberChannels == (inputFormat.isInterleaved ? inputFormat.channels : 1),
                  Int(inputs[index].mDataByteSize) == frames * Int(inputFormat.bytesPerFrame) else {
                fault.store(1, ordering: .relaxed); return
            }
        }
        for index in 0..<outputCount {
            guard outputs[index].mData != nil,
                  outputs[index].mNumberChannels == (outputFormat.isInterleaved ? outputFormat.channels : 1),
                  Int(outputs[index].mDataByteSize) == frames * Int(outputFormat.bytesPerFrame) else {
                fault.store(1, ordering: .relaxed); return
            }
        }
        let desired = Float(bitPattern: targetGain.load(ordering: .relaxed))
        var limited = false
        var blockInputPeak: Float = 0
        var blockOutputPeak: Float = 0
        for frame in 0..<frames {
            currentGain += (desired - currentGain) * smoothing
            var peak: Float = 0
            for channel in 0..<Int(inputFormat.channels) {
                let source = inputs[inputFormat.isInterleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
                let sample = source[inputFormat.isInterleaved ? frame * Int(inputFormat.channels) + channel : frame]
                if sample.isFinite {
                    blockInputPeak = max(blockInputPeak, abs(sample))
                    peak = max(peak, abs(sample * currentGain))
                }
            }
            let requiredLimit: Float = peak > 1 ? 1 / peak : 1
            if requiredLimit < limiterGain { limiterGain = requiredLimit }
            else { limiterGain += (requiredLimit - limiterGain) * limiterRelease }
            if limiterGain < 0.999 { limited = true }
            for channel in 0..<Int(outputFormat.channels) {
                let source = inputs[inputFormat.isInterleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
                let destination = outputs[outputFormat.isInterleaved ? 0 : channel].mData!.assumingMemoryBound(to: Float.self)
                let sample = source[inputFormat.isInterleaved ? frame * Int(inputFormat.channels) + channel : frame]
                let processed = sample * currentGain * limiterGain
                let safeOutput = processed.isFinite ? min(1, max(-1, processed)) : 0
                destination[outputFormat.isInterleaved ? frame * Int(outputFormat.channels) + channel : frame] = safeOutput
                blockOutputPeak = max(blockOutputPeak, abs(safeOutput))
            }
        }
        peakLimited.store(limited, ordering: .relaxed)
        inputPeak.store(blockInputPeak.bitPattern, ordering: .relaxed)
        outputPeak.store(blockOutputPeak.bitPattern, ordering: .relaxed)
        if blockInputPeak > 0 { hasReceivedAudio.store(true, ordering: .relaxed) }
        sequence.wrappingAdd(1, ordering: .relaxed)
    }
}

private let applicationAudioIOProc: AudioDeviceIOProc = { _, _, input, _, output, _, pointer in
    guard let pointer else { return noErr }
    Unmanaged<ApplicationAudioRenderContext>.fromOpaque(pointer).takeUnretainedValue().render(input: input, output: output)
    return noErr
}
