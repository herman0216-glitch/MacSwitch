import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let model: AppModel
    @State private var tab = 0
    @State private var selectedFeature: FeatureID?

    var body: some View {
        TabView(selection: $tab) {
            general.tabItem { Label("通用", systemImage: "gearshape") }.tag(0)
            switches.tabItem { Label("开关", systemImage: "switch.2") }.tag(1)
            shortcuts.tabItem { Label("快捷键", systemImage: "keyboard") }.tag(2)
            about.tabItem { Label("关于", systemImage: "info.circle") }.tag(3)
        }
        .padding(20)
        .frame(width: 570, height: 470)
        .onAppear { NSApp.activate(ignoringOtherApps: true); model.loginItem.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.loginItem.refresh() }
    }

    private var general: some View {
        Form {
            Section {
                Toggle("登录时启动 MacSwitch", isOn: Binding(get: { model.loginItem.enabled }, set: { value in Task { await model.loginItem.setEnabled(value) } }))
                    .disabled(model.loginItem.busy)
                if let message = model.loginItem.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    Button("打开登录项设置") { model.loginItem.openSystemSettings() }
                }
            } footer: { Text("MacSwitch 常驻菜单栏，不显示 Dock 图标。") }
            Section("权限与系统行为") {
                Text("深色模式首次使用时请求自动化权限，仅用于控制 System Events 的外观设置。拒绝后仍可使用其他开关。")
                Button("打开自动化权限设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") { NSWorkspace.shared.open(url) }
                }
                Text("麦克风静音直接控制当前输入设备；日常使用不会录音，也不请求麦克风录制或辅助功能权限。")
                Text("屏幕键盘清洁按需使用辅助功能权限。开启后只通过屏幕中央按钮退出；电源键与系统安全界面仍由 macOS 管理。")
                Text("应用音量控制按需使用系统音频录制权限，仅在本机内存处理，不保存、不上传音频。关闭音量控制后停止处理并恢复原声。")
                Text("隐藏桌面图标会短暂刷新 Finder，可能中断 Finder 中的选中或拖动状态。桌面文件始终保留原位。")
                Text("防休眠可阻止闲置休眠；合盖、主动睡眠或关机仍由系统处理。退出应用会释放防休眠。")
            }
            .font(.callout)
            if let warning = model.preferences.warning { Text(warning).foregroundStyle(.orange) }
        }
        .formStyle(.grouped)
    }

    private var switches: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("菜单栏中显示的开关").font(.headline)
            Text("拖动列表行调整顺序，或选中后使用下方箭头。隐藏开关不会关闭功能或取消快捷键。")
                .font(.callout).foregroundStyle(.secondary)
            List(selection: $selectedFeature) {
                ForEach(model.preferences.value.order) { feature in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).accessibilityHidden(true)
                        Label(feature.title, systemImage: feature.symbol)
                        Spacer()
                        Toggle("显示\(feature.title)", isOn: Binding(get: { !model.preferences.value.hidden.contains(feature) }, set: { model.preferences.setVisible($0, for: feature) }))
                            .labelsHidden().toggleStyle(.checkbox)
                    }
                    .padding(.vertical, 7).tag(feature)
                    .contentShape(Rectangle())
                    .onDrag { NSItemProvider(object: feature.rawValue as NSString) }
                    .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
                        guard let provider = providers.first, provider.canLoadObject(ofClass: NSString.self) else { return false }
                        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                            guard let rawValue = object as? String, let source = FeatureID(rawValue: rawValue) else { return }
                            Task { @MainActor in model.preferences.move(source, to: feature) }
                        }
                        return true
                    }
                }
            }
            .listStyle(.inset).border(.quaternary, width: 1)
            HStack {
                Button { moveSelection(-1) } label: { Image(systemName: "arrow.up") }
                    .help("上移选中的开关").accessibilityLabel("上移选中的开关")
                    .disabled(selectionIndex == nil || selectionIndex == 0)
                Button { moveSelection(1) } label: { Image(systemName: "arrow.down") }
                    .help("下移选中的开关").accessibilityLabel("下移选中的开关")
                    .disabled(selectionIndex == nil || selectionIndex == model.preferences.value.order.count - 1)
                Spacer()
                Button("恢复默认排列") { model.preferences.setOrder(FeatureID.allCases) }
            }
        }
        .padding(.top, 14)
    }

    private var selectionIndex: Int? { selectedFeature.flatMap { model.preferences.value.order.firstIndex(of: $0) } }
    private func moveSelection(_ delta: Int) {
        guard let index = selectionIndex else { return }
        let target = index + delta
        var order = model.preferences.value.order
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        model.preferences.setOrder(order)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("全局快捷键").font(.headline)
            Text("点击录制后按下组合键。至少包含 ⌘、⌃ 或 ⌥；Esc 取消。未设置的功能不占用任何快捷键。")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 14) {
                    ForEach(model.preferences.value.order) { feature in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(feature.title, systemImage: feature.symbol).frame(width: 150, alignment: .leading)
                                Spacer()
                                ShortcutRecorder(shortcut: model.preferences.value.shortcuts[feature]) { shortcut in
                                    try model.record(shortcut, for: feature)
                                }
                            }
                            if let error = model.shortcutErrors[feature] {
                                Text(error).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        if feature != model.preferences.value.order.last { Divider() }
                    }
                }.padding(.vertical, 8)
            }
            Text("若其他应用占用了组合键，会保留原绑定并提示冲突。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.top, 14)
    }

    private var about: some View {
        VStack(spacing: 14) {
            Image(systemName: "switch.2").font(.system(size: 48)).foregroundStyle(.tint)
            Text("MacSwitch").font(.title.bold())
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                .foregroundStyle(.secondary)
            Text("七个常用开关，随时从菜单栏使用。\n为 macOS 26 及以上版本设计。")
                .multilineTextAlignment(.center)
            Divider().padding(.vertical, 4)
            Text("本地运行 · 无账户 · 无联网服务").font(.callout).foregroundStyle(.secondary)
            Text("桌面恢复：若 Finder 意外未刷新，可再次切换“隐藏桌面图标”，或在访达中重新打开桌面文件夹。详细恢复命令见随附使用说明。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
