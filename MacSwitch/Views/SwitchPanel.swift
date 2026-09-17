import SwiftUI

struct SwitchPanel: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacSwitch").font(.headline)
                    Text("常用系统开关").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.coordinator.refreshAll() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("刷新系统状态").accessibilityLabel("刷新系统状态")
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider()
            if model.preferences.visibleFeatures.isEmpty {
                Text("所有开关已隐藏\n在设置中选择要显示的开关。")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(24)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.preferences.visibleFeatures) { id in
                        SwitchRow(feature: id, model: model)
                        if id != model.preferences.visibleFeatures.last { Divider().padding(.leading, 54) }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: max(200, (NSScreen.main?.visibleFrame.height ?? 800) - 190))
            .fixedSize(horizontal: false, vertical: true)
            if let message = model.volume.cleanupMessage {
                Text(message).font(.caption).foregroundStyle(.orange).padding(.horizontal, 18).padding(.bottom, 8)
            }
            Divider()
            HStack {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: { Label("设置…", systemImage: "gearshape") }
                .keyboardShortcut(",")
                Spacer()
                Button("退出") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
            .buttonStyle(.borderless).font(.callout)
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 340)
        .task { model.coordinator.refreshAll() }
    }
}

private struct SwitchRow: View {
    let feature: FeatureID
    let model: AppModel
    private var state: FeatureState { model.coordinator.state(feature) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: feature.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(state.snapshot.isEnabled ? Color.accentColor : Color.secondary)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feature.title).font(.system(size: 13, weight: .medium))
                    if let detail = state.snapshot.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    } else if !state.hasRead {
                        Text("正在读取…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 6)
                if state.isBusy {
                    ProgressView().controlSize(.small).accessibilityLabel("正在处理")
                } else if state.phase == .succeeded {
                    Image(systemName: "checkmark").font(.caption).foregroundStyle(.secondary).help("已更新")
                }
                Toggle(feature.title, isOn: Binding(get: { state.snapshot.isEnabled }, set: { model.coordinator.setEnabled($0, for: feature) }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(state.isBusy || state.isUnsupported || !state.hasRead)
                    .accessibilityIdentifier("toggle.\(feature.rawValue)")
            }
            if feature == .keepAwake {
                Picker("防休眠时长", selection: Binding(get: { model.preferences.value.awakeDuration }, set: { model.setDuration($0) })) {
                    ForEach(AwakeDuration.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).controlSize(.small)
                .disabled(state.isBusy).padding(.leading, 40)
                .help("开启时更改时长会重新计时")
            }
            if feature == .volumeControl, model.volume.isEnabled {
                VolumePanel(volume: model.volume)
            }
            if state.phase.isError, let message = state.phase.message {
                VStack(alignment: .leading, spacing: 4) {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    if !state.isUnsupported {
                        if feature == .cleaning {
                            Button("打开辅助功能设置") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                    NSWorkspace.shared.open(url)
                                }
                            }.font(.caption).buttonStyle(.link)
                        }
                        Button("重试") { model.coordinator.retry(feature) }.font(.caption).buttonStyle(.link)
                    }
                }.padding(.leading, 40)
            }
        }
        .padding(.vertical, 11)
    }
}
