import AppKit

@MainActor
protocol AppearanceBackend: AnyObject {
    func readDarkMode() -> Bool
}

@MainActor
final class SystemAppearanceBackend: AppearanceBackend {
    func readDarkMode() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let style = CFPreferencesCopyValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
        return style == "Dark"
    }
}

@MainActor
final class AppearanceService: SwitchService {
    let id: FeatureID = .appearance
    var onChange: (@MainActor () -> Void)?
    private let backend: any AppearanceBackend
    private let transitionBackend: (any AppearanceTransitionBackend)?
    private var stopped = false
    private var observer: NSObjectProtocol?

    convenience init() {
        self.init(backend: SystemAppearanceBackend(),
                  transitionBackend: NativeAppearanceTransitionBackend.systemBackend())
    }

    init(backend: any AppearanceBackend, transitionBackend: (any AppearanceTransitionBackend)?) {
        self.backend = backend
        self.transitionBackend = transitionBackend
        observer = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onChange?() }
        }
    }

    func read() async throws -> SwitchSnapshot {
        let enabled = backend.readDarkMode()
        guard let transitionBackend, transitionBackend.isAvailable else {
            return SwitchSnapshot(isEnabled: enabled, detail: "此系统暂不支持原生外观切换", availability: .unsupported("原生外观接口不可用。"))
        }
        return SwitchSnapshot(isEnabled: enabled, detail: "跟随系统当前外观")
    }

    func setEnabled(_ enabled: Bool) async throws -> SwitchSnapshot {
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        guard let transitionBackend, transitionBackend.isAvailable else {
            throw SwitchFailure.unsupported("原生外观接口不可用。")
        }
        do {
            try await transitionBackend.setDarkMode(enabled)
        } catch {
            guard !stopped else { throw CancellationError() }
            try Task.checkCancellation()
            // A missing callback can follow a successful write. Never repeat it.
            if backend.readDarkMode() == enabled { return SwitchSnapshot(isEnabled: enabled, detail: "跟随系统当前外观") }
            throw error
        }
        guard !stopped else { throw CancellationError() }
        try Task.checkCancellation()
        for _ in 0..<15 {
            let state = try await read()
            if state.isEnabled == enabled { return state }
            try await Task.sleep(for: .milliseconds(100))
            guard !stopped else { throw CancellationError() }
            try Task.checkCancellation()
        }
        transitionBackend.shutdown()
        throw SwitchFailure.failed("系统未确认外观变化，请刷新后重试。")
    }

    func shutdown() {
        stopped = true
        transitionBackend?.shutdown()
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }
}
