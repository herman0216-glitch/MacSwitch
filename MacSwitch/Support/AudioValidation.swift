#if DEBUG
import AppKit
import CoreAudio

/// Explicit development entry point. Collects only numerical levels of the two
/// task-owned tone apps; no PCM is written, and system volume is never changed.
@MainActor
enum AudioValidation {
    static func run(resultURL: URL) async {
        var report: [String: Any] = ["date": Date().ISO8601Format(), "passed": false]
        var mixers: [ApplicationAudioMixer] = []
        do {
            let device = try AudioHAL.defaultOutputDevice()
            var apps: [DiscoveredAudioApplication] = []
            for _ in 0..<30 {
                apps = ApplicationAudioDiscovery().discover(defaultDevice: device).filter {
                    $0.name == "MacSwitch Tone A" || $0.name == "MacSwitch Tone B"
                }
                if apps.count == 2 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            report["device"] = try AudioHAL.outputDescriptor(for: device).name
            report["discovered"] = apps.map { ["name": $0.name, "processes": $0.processObjectIDs,
                                               "reason": $0.unsupportedReason ?? ""] as [String: Any] }
            guard apps.count == 2 else { throw AudioHALError(message: "需要两个正在播放的专属测试音源。") }
            for app in apps {
                let mixer = ApplicationAudioMixer()
                mixers.append(mixer)
                try mixer.start(application: app, outputDevice: device,
                                gain: AudioGainResult(linearGain: 1, isAmplificationLimited: false, usesApproximateCurve: false))
            }
            try await Task.sleep(for: .seconds(2))
            report["unity"] = mixers.map { metrics($0.status) }
            guard mixers.allSatisfy({ $0.status.hasReceivedAudio && $0.status.isRunning }) else {
                throw AudioHALError(message: "尚未收到两个测试音源的实际PCM；请检查系统音频录制权限。")
            }
            let defaultUnchanged = try AudioHAL.defaultOutputDevice() == device
            let unity = mixers.allSatisfy { abs($0.status.outputPeak - $0.status.inputPeak) < 0.002 }
            mixers[0].updateGain(AudioGainResult(linearGain: 0, isAmplificationLimited: false, usesApproximateCurve: false))
            try await Task.sleep(for: .milliseconds(500))
            report["oneSilent"] = mixers.map { metrics($0.status) }
            let independent = mixers[0].status.outputPeak < 0.00001 && mixers[1].status.outputPeak > 0.001
            let boost = AudioGain.calculate(targetPercent: 100, outputPercent: 10, decibels: { AudioHAL.volumeDecibels(device: device, scalar: $0) })
            mixers[0].updateGain(boost)
            try await Task.sleep(for: .milliseconds(500))
            report["boostLimited"] = mixers.map { metrics($0.status) }
            let bounded = mixers[0].status.isLimiting && mixers[0].status.outputPeak <= mixers[0].status.inputPeak * 3.982 + 0.001
            for mixer in mixers { mixer.stop() }
            try await Task.sleep(for: .milliseconds(300))
            let released = mixers.allSatisfy { !$0.status.isRunning && !$0.status.requiresCleanup }
            report["released"] = released
            let finalDefaultUnchanged = try AudioHAL.defaultOutputDevice() == device
            report["defaultUnchanged"] = defaultUnchanged && finalDefaultUnchanged
            report["passed"] = unity && independent && bounded && released && defaultUnchanged && finalDefaultUnchanged
            report["boundary"] = "两个合成音源的真实HAL/PCM验证；物理听感、微信通话、浏览器直播及外设需单独验收。"
        } catch { report["error"] = error.localizedDescription }
        for mixer in mixers { mixer.stop() }
        do {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: resultURL, options: .atomic)
        } catch { NSLog("Audio validation report write failed: %@", error.localizedDescription) }
    }

    private static func metrics(_ status: ApplicationAudioMixerStatus) -> [String: Any] {
        ["running": status.isRunning, "receivedAudio": status.hasReceivedAudio,
         "callbacks": status.callbackCount, "inputPeak": status.inputPeak,
         "outputPeak": status.outputPeak, "limiting": status.isLimiting,
         "requiresCleanup": status.requiresCleanup, "message": status.message ?? ""]
    }
}
#endif
