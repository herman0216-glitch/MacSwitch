import AppKit
import AVFoundation

/// Task-owned tone source. No microphone or captured audio is used.
private final class Oscillator: @unchecked Sendable {
    private var phase = 0.0 // only the render callback mutates this
    let step: Double
    init(frequency: Double, sampleRate: Double) { step = 2 * .pi * frequency / sampleRate }
    func render(frames: UInt32, buffers: UnsafeMutablePointer<AudioBufferList>) {
        let output = UnsafeMutableAudioBufferListPointer(buffers)
        for frame in 0..<Int(frames) {
            let sample = Float(sin(phase)) * 0.025
            phase += step
            if phase >= 2 * .pi { phase -= 2 * .pi }
            for buffer in output {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for channel in 0..<Int(buffer.mNumberChannels) { data[frame * Int(buffer.mNumberChannels) + channel] = sample }
            }
        }
    }
}

// Defined outside MainActor so the real-time render closure never inherits the
// application's actor executor (Swift 6 checks that at runtime).
private func makeToneSource(format: AVAudioFormat, frequency: Double) -> AVAudioSourceNode {
    let oscillator = Oscillator(frequency: frequency, sampleRate: format.sampleRate)
    return AVAudioSourceNode(format: format) { _, _, frames, buffers in
        oscillator.render(frames: frames, buffers: buffers)
        return noErr
    }
}

@main
enum ToneProbe {
    @MainActor static func main() throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let engine = AVAudioEngine()
        let format = engine.outputNode.inputFormat(forBus: 0)
        let frequency = Bundle.main.bundleIdentifier?.hasSuffix("ToneA") == true ? 440.0 : 660.0
        let source = makeToneSource(format: format, frequency: frequency)
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
        let arguments = CommandLine.arguments
        let durationIndex = arguments.firstIndex(of: "--duration").map { $0 + 1 }
        let duration = durationIndex.flatMap { arguments.indices.contains($0) ? Double(arguments[$0]) : nil } ?? 180
        let seconds = duration.isFinite ? min(900, max(1, duration)) : 180
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { engine.stop(); application.terminate(nil) }
        application.run()
        engine.stop()
    }
}
