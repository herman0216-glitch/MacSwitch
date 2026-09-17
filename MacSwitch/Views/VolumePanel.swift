import SwiftUI

struct VolumePanel: View {
    let volume: VolumeControlService

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VolumeSlider(title: "提醒音量", symbol: "bell.fill", value: volume.alertValue,
                         identifier: "volume.alert", set: volume.setAlertVolume)
            VStack(alignment: .leading, spacing: 4) {
                VolumeSlider(title: "输出音量", symbol: "speaker.wave.2.fill", value: volume.outputValue,
                             identifier: "volume.output", set: volume.setOutputVolume)
                    .disabled(volume.system?.outputAvailability != .available)
                Text(volume.system?.deviceName ?? "正在读取输出设备…")
                    .font(.caption).foregroundStyle(.secondary)
                if volume.system?.isMuted == true {
                    Label("系统已静音，音量数值已保留", systemImage: "speaker.slash")
                        .font(.caption).foregroundStyle(.secondary)
                } else if volume.system?.outputVolume == 0 {
                    Text("系统输出为 0，所有应用无声；仍可设置应用目标。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if case .unsupported(let reason) = volume.system?.outputAvailability {
                    Text(reason).font(.caption).foregroundStyle(.orange)
                }
            }
            if let error = volume.systemError {
                Text(error).font(.caption).foregroundStyle(.orange)
                Button("重试系统音量") { volume.requestRefresh() }.buttonStyle(.link).font(.caption)
            }
            Divider()
            Text("应用音量").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            if let message = volume.applicationMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(volume.applications) { row in
                ApplicationVolumeSlider(row: row, volume: volume)
            }
            if volume.applications.contains(where: { !$0.isRunning && $0.application.unsupportedReason == nil }) {
                Text("应用音量需要系统音频录制权限。允许后点击重试；音频仅在本机内存处理。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("打开权限设置") { openAudioPrivacySettings() }
                    Spacer()
                    Button("重试应用音量") { volume.retryApplicationAudio() }
                }.buttonStyle(.link).font(.caption)
            }
            Text("应用百分比为目标音量；提醒音量不参与联动。")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.leading, 40).padding(.top, 8).padding(.bottom, 5)
    }

    private func openAudioPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct VolumeSlider: View {
    let title: String
    let symbol: String
    let value: Double
    let identifier: String
    let set: (Double) -> Void

    var body: some View {
        VStack(spacing: 5) {
            HStack {
                Label(title, systemImage: symbol).font(.callout)
                Spacer(minLength: 4)
                Text("\(Int(value.rounded()))%")
                    .monospacedDigit().font(.caption).foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: set), in: 0...100, step: 1)
                .controlSize(.small)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int(value)) 百分比")
                .accessibilityIdentifier(identifier)
        }
    }
}

private struct ApplicationVolumeSlider: View {
    let row: ApplicationVolumeRow
    let volume: VolumeControlService

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                if let path = row.application.bundleURL?.path {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 20, height: 20)
                } else {
                    Image(systemName: "app").frame(width: 20, height: 20).foregroundStyle(.secondary)
                }
                Text(row.application.name).font(.callout).lineLimit(1).help(row.application.name)
                Spacer(minLength: 4)
                Text("\(Int(row.target))%")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { row.target }, set: { volume.setApplicationVolume($0, for: row.id) }), in: 0...100, step: 1)
                .controlSize(.small)
                .disabled(!row.isRunning)
                .accessibilityLabel("\(row.application.name)目标音量")
                .accessibilityValue("\(Int(row.target)) 百分比")
                .accessibilityIdentifier("volume.app.\(row.id)")
            if let message = row.message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                if row.isLimited {
                    Label("放大受限", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                        .help("补偿放大最多＋12 dB，并受音源峰值限制。目标百分比不代表实际响度已达到。")
                }
                if row.isApproximate {
                    Text("近似音量映射：设备未提供可用曲线")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
