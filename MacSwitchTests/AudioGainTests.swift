import CoreAudio
import Foundation
import Testing
@testable import MacSwitch

struct AudioGainTests {
    private func nativeCurve(_ scalar: Float) -> Float? { -63.5 * (1 - scalar) }

    @Test func newApplicationPreservesOriginalGain() {
        for level in [1.0, 30, 60, 100] {
            let result = AudioGain.calculate(targetPercent: level, outputPercent: level, decibels: nativeCurve)
            #expect(result.linearGain == 1)
            #expect(!result.isAmplificationLimited)
            #expect(!result.usesApproximateCurve)
        }
    }

    @Test func deviceCurveCompensatesMasterAttenuationAndCapsBoost() {
        let boost = AudioGain.calculate(targetPercent: 80, outputPercent: 60, decibels: nativeCurve)
        #expect(abs(boost.linearGain - 3.981072) < 0.00001)
        #expect(boost.isAmplificationLimited)
        let attenuation = AudioGain.calculate(targetPercent: 60, outputPercent: 80, decibels: nativeCurve)
        #expect(abs(attenuation.linearGain - pow(10, -12.7 / 20)) < 0.00001)
        #expect(!attenuation.isAmplificationLimited)
    }

    @Test func missingOrInvalidCurvesAreClearlyApproximate() {
        let missing = AudioGain.calculate(targetPercent: 80, outputPercent: 60) { _ in nil }
        #expect(abs(missing.linearGain - 4.0 / 3) < 0.00001)
        #expect(missing.usesApproximateCurve)
        let invalid = AudioGain.calculate(targetPercent: 80, outputPercent: 60) { _ in .nan }
        #expect(invalid == missing)
    }

    @Test func zeroAndMuteNeverAmplifyAndNonfiniteValuesAreSafe() {
        #expect(AudioGain.calculate(targetPercent: 100, outputPercent: 0, decibels: nativeCurve).linearGain == 0)
        #expect(AudioGain.calculate(targetPercent: 0, outputPercent: 50, decibels: nativeCurve).linearGain == 0)
        #expect(AudioGain.calculate(targetPercent: 80, outputPercent: 60, muted: true, decibels: nativeCurve).linearGain == 0)
        #expect(AudioGain.calculate(targetPercent: .nan, outputPercent: 60, decibels: nativeCurve).linearGain == 0)
        #expect(AudioGain.calculate(targetPercent: 80, outputPercent: .infinity, decibels: nativeCurve).linearGain == 0)
    }

    @Test func rendererPreservesStereoAndKeepsApplicationGainIndependent() throws {
        let format = try pcm(channels: 2)
        let first = ApplicationAudioRenderContext(input: format, output: format, initialGain: 1)
        let second = ApplicationAudioRenderContext(input: format, output: format, initialGain: 0.5)
        let samples: [Float] = [0.25, -0.5, 0.75, -0.25]
        #expect(render(first, samples: samples, channels: 2) == samples)
        #expect(render(second, samples: samples, channels: 2) == samples.map { $0 * 0.5 })
        let receivedAudio = first.hasReceivedAudio.load(ordering: .relaxed)
        #expect(receivedAudio)
        #expect(first.sequence.load(ordering: .relaxed) == 1)
    }

    @Test func limiterPreventsPeaksAndNonfiniteSamplesFromEscaping() throws {
        let format = try pcm(channels: 2)
        let context = ApplicationAudioRenderContext(input: format, output: format, initialGain: 3.981072)
        let output = render(context, samples: [2, -2, .nan, .infinity], channels: 2)
        #expect(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(output[0] > 0.99 && output[1] < -0.99)
        #expect(output[2] == 0 && output[3] == 0)
        let limited = context.peakLimited.load(ordering: .relaxed)
        #expect(limited)
    }

    @Test func changingGainIsSmoothedAcrossFrames() throws {
        let format = try pcm(channels: 1)
        let context = ApplicationAudioRenderContext(input: format, output: format, initialGain: 1)
        context.targetGain.store(Float(0).bitPattern, ordering: .relaxed)
        let output = render(context, samples: Array(repeating: 0.5, count: 1024), channels: 1)
        #expect(output[0] > 0.49 && output[0] < 0.5)
        #expect(output.last! < 0.1)
        #expect(zip(output, output.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test func invalidBufferLayoutProducesSilenceAndFault() throws {
        let format = try pcm(channels: 2)
        let context = ApplicationAudioRenderContext(input: format, output: format, initialGain: 1)
        let output = render(context, samples: [0.5, 0.5], channels: 1)
        #expect(output == [0, 0])
        #expect(context.fault.load(ordering: .relaxed) != 0)
        #expect(context.sequence.load(ordering: .relaxed) == 0)
    }

    @Test func unsupportedPCMFormatsAreRejectedBeforeCapture() throws {
        var format = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 24, mFramesPerPacket: 1, mBytesPerFrame: 24,
                                                 mChannelsPerFrame: 6, mBitsPerChannel: 32, mReserved: 0)
        #expect(throws: AudioHALError.self) { try AudioPCMFormat(format) }
        format.mChannelsPerFrame = 2
        format.mBitsPerChannel = 16
        format.mFormatFlags = kAudioFormatFlagIsSignedInteger
        #expect(throws: AudioHALError.self) { try AudioPCMFormat(format) }
    }

    private func pcm(channels: UInt32) throws -> AudioPCMFormat {
        try AudioPCMFormat(AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                                       mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                       mBytesPerPacket: channels * 4, mFramesPerPacket: 1,
                                                       mBytesPerFrame: channels * 4, mChannelsPerFrame: channels,
                                                       mBitsPerChannel: 32, mReserved: 0))
    }

    private func render(_ context: ApplicationAudioRenderContext, samples: [Float], channels: UInt32) -> [Float] {
        var source = samples
        var result = [Float](repeating: 99, count: samples.count)
        let byteCount = UInt32(samples.count * MemoryLayout<Float>.stride)
        source.withUnsafeMutableBytes { inputBytes in
            result.withUnsafeMutableBytes { outputBytes in
                var input = AudioBufferList(mNumberBuffers: 1,
                                            mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: byteCount,
                                                                  mData: inputBytes.baseAddress))
                var output = AudioBufferList(mNumberBuffers: 1,
                                             mBuffers: AudioBuffer(mNumberChannels: channels, mDataByteSize: byteCount,
                                                                   mData: outputBytes.baseAddress))
                context.render(input: &input, output: &output)
            }
        }
        return result
    }
}
