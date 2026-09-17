import SwiftUI

@main
struct MacSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            SwitchPanel(model: model)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
        .defaultSize(width: 570, height: 470)
        .windowResizability(.contentSize)
        .commands {
            CommandMenu("开关") {
                ForEach(FeatureID.allCases) { feature in
                    Toggle(feature.title, isOn: Binding(
                        get: { model.coordinator.state(feature).snapshot.isEnabled },
                        set: { model.coordinator.setEnabled($0, for: feature) }
                    ))
                    .disabled(model.coordinator.state(feature).isBusy || model.coordinator.state(feature).isUnsupported)
                }
                Divider()
                Button("刷新系统状态") { model.coordinator.refreshAll() }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "--verify-audio"), args.indices.contains(index + 1), args[index + 1].hasPrefix("/") {
            Task { @MainActor in await AudioValidation.run(resultURL: URL(fileURLWithPath: args[index + 1])) }
        }
        #endif
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NotificationCenter.default.post(name: .showMacSwitchSettings, object: nil)
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let model = AppModel.shared
        model.beginStopping()
        guard model.coordinator.isBusy || model.volume.hasInFlightOperations else { model.shutdown(); return .terminateNow }
        Task { @MainActor in
            await model.coordinator.waitUntilIdle()
            await model.volume.waitUntilIdle()
            model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    func applicationWillTerminate(_ notification: Notification) { AppModel.shared.shutdown() }
}

private extension Notification.Name {
    static let showMacSwitchSettings = Notification.Name("MacSwitch.showSettings")
}

private struct MenuBarLabel: View {
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        Image("MenuBarIcon")
            .renderingMode(.template)
            .accessibilityLabel("MacSwitch")
            .onReceive(NotificationCenter.default.publisher(for: .showMacSwitchSettings)) { _ in
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
    }
}
