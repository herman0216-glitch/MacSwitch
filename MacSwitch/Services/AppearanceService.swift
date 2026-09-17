import AppKit
import Carbon

@MainActor
protocol AppearanceBackend: AnyObject {
    func readDarkMode() -> Bool
    func ensureSystemEventsRunning() async throws
    func requestAutomationPermission() async throws
    func setDarkMode(_ enabled: Bool) async throws
}

@MainActor
final class SystemAppearanceBackend: AppearanceBackend {
    func readDarkMode() -> Bool {
        // Reading preferences does not prompt for Automation on application launch.
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        return style == "Dark"
    }

    func ensureSystemEventsRunning() async throws {
        // Permission preflight does not launch its target (it returns procNotFound).
        // System Events automatically exits when idle, so ensure it is running.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systemevents").isEmpty {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.systemevents") else {
                throw SwitchFailure.unsupported("此系统未找到 System Events，无法控制系统外观。")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.addsToRecentItems = false
            do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration) }
            catch { throw SwitchFailure.failed("无法启动系统外观服务，请稍后重试。") }
        }
    }

    func requestAutomationPermission() async throws {
        // Consent can wait for the user and must remain outside the script timeout.
        try await Task.detached(priority: .userInitiated) {
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
            let consent = AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
            if consent == errAEEventNotPermitted || consent == errAEEventWouldRequireUserConsent {
                throw SwitchFailure.unauthorized("请在系统设置 → 隐私与安全性 → 自动化中，允许 MacSwitch 控制 System Events。")
            }
            guard consent == noErr else {
                throw SwitchFailure.failed("无法确认自动化权限（\(consent)），请重试。")
            }
        }.value
    }

    func setDarkMode(_ enabled: Bool) async throws {
        // Execute from the app, so consent is attributed to MacSwitch, not Terminal.
        let source = "tell application \"System Events\" to tell appearance preferences to set dark mode to \(enabled ? "true" : "false")"
        try await Task.detached(priority: .userInitiated) {
            guard let script = NSAppleScript(source: "with timeout of 15 seconds\n\(source)\nend timeout") else {
                throw SwitchFailure.failed("无法创建系统外观操作。")
            }
            var errorInfo: NSDictionary?
            script.executeAndReturnError(&errorInfo)
            if let errorInfo {
                let code = errorInfo[NSAppleScript.errorNumber] as? Int ?? 0
                if code == -1743 || code == -1744 {
                    throw SwitchFailure.unauthorized("请在系统设置 → 隐私与安全性 → 自动化中，允许 MacSwitch 控制 System Events。")
                }
                throw SwitchFailure.failed("系统外观切换失败（\(code)），请重试。")
            }
        }.value
    }
}

@MainActor
final class AppearanceService: SwitchService {
    let id: FeatureID = .appearance
    var onChange: (@MainActor () -> Void)?
    private let backend: any AppearanceBackend
    private var observer: NSObjectProtocol?

    init(backend: any AppearanceBackend = SystemAppearanceBackend()) {
        self.backend = backend
        observer = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onChange?() }
        }
    }

    func read() async throws -> SwitchSnapshot {
        SwitchSnapshot(isEnabled: backend.readDarkMode(), detail: "跟随系统当前外观")
    }

    func setEnabled(_ enabled: Bool) async throws -> SwitchSnapshot {
        // Check consent on every operation so a revoked grant cannot be cached.
        try await backend.ensureSystemEventsRunning()
        try await backend.requestAutomationPermission()
        try await backend.setDarkMode(enabled)
        for _ in 0..<15 {
            let state = try await read()
            if state.isEnabled == enabled { return state }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SwitchFailure.failed("系统未确认外观变化，请刷新后重试。")
    }

    func shutdown() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }
}
