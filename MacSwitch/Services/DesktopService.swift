import AppKit

@MainActor
protocol DesktopBackend: AnyObject {
    func preference() -> Bool?
    func write(_ value: Bool?) throws
    func restartFinder() async throws
}

@MainActor
final class FinderDesktopBackend: DesktopBackend {
    private let domain = "com.apple.finder" as CFString
    private let key = "CreateDesktop" as CFString

    func preference() -> Bool? {
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue(key, domain) as? Bool
    }

    func write(_ value: Bool?) throws {
        CFPreferencesSetAppValue(key, value.map { $0 as CFBoolean }, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            throw SwitchFailure.failed("无法保存 Finder 的桌面偏好。")
        }
    }

    func restartFinder() async throws {
        let oldPID = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.processIdentifier
        if oldPID != nil {
            let result = try await ProcessRunner.run("/usr/bin/killall", ["-TERM", "Finder"], timeout: 5)
            guard result.status == 0 else { throw SwitchFailure.failed("Finder 未能刷新，请稍后重试。") }
        }
        // launchd normally restarts Finder. Explicitly open it only if still absent.
        for attempt in 0..<40 {
            if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
               finder.processIdentifier != oldPID, finder.isFinishedLaunching {
                try await Task.sleep(for: .milliseconds(250))
                return
            }
            if attempt == 15 {
                _ = try await ProcessRunner.run("/usr/bin/open", ["-g", "-a", "Finder"], timeout: 5)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw SwitchFailure.failed("Finder 刷新超时，已尝试恢复原偏好。")
    }
}

@MainActor
final class DesktopService: SwitchService {
    let id: FeatureID = .desktop
    var onChange: (@MainActor () -> Void)?
    private let backend: any DesktopBackend
    private var observer: NSObjectProtocol?

    init(backend: any DesktopBackend = FinderDesktopBackend()) {
        self.backend = backend
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.finder" else { return }
            Task { @MainActor [weak self] in self?.onChange?() }
        }
    }

    func read() async throws -> SwitchSnapshot {
        SwitchSnapshot(isEnabled: !(backend.preference() ?? true), detail: "切换时会短暂刷新 Finder")
    }

    func setEnabled(_ enabled: Bool) async throws -> SwitchSnapshot {
        let original = backend.preference()
        if !(original ?? true) == enabled { return try await read() }
        do {
            try backend.write(!enabled)
            try await backend.restartFinder()
            let result = try await read()
            guard result.isEnabled == enabled else { throw SwitchFailure.failed("桌面偏好未生效。") }
            return result
        } catch {
            let cause = error.localizedDescription
            do {
                try backend.write(original)
                try await backend.restartFinder()
            } catch {
                throw SwitchFailure.failed("\(cause) 恢复未完成：\(error.localizedDescription) 请在设置中查看桌面恢复说明。")
            }
            throw SwitchFailure.failed("\(cause) 已恢复原桌面偏好。")
        }
    }

    func shutdown() {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
    }
}
