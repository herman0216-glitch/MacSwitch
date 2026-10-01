import AppKit
@preconcurrency import ApplicationServices
import IOKit.pwr_mgt
import OSLog

@MainActor
protocol CleaningBackend: AnyObject {
    var onFailure: (@MainActor (String) -> Void)? { get set }
    var onExit: (@MainActor () -> Void)? { get set }
    var isHealthy: Bool { get }
    var unavailabilityReason: String? { get }
    func start() async throws
    func stop()
}

extension CleaningBackend { var unavailabilityReason: String? { nil } }

/// Owns the whole cleaning session. Startup is transactional: failure at any
/// stage releases the event tap, windows, presentation options and power lease.
@MainActor
final class CleaningService: SwitchService {
    let id: FeatureID = .cleaning
    var onChange: (@MainActor () -> Void)?
    var onSessionChange: (@MainActor (Bool) -> Void)?
    private let backend: any CleaningBackend
    private(set) var isEnabled = false
    private var failure: String?
    private var stopped = false
    private var session: UUID?

    init(backend: (any CleaningBackend)? = nil) {
        self.backend = backend ?? AppKitCleaningBackend()
        self.backend.onExit = { [weak self] in self?.stop() }
        self.backend.onFailure = { [weak self] reason in
            self?.stop()
            self?.failure = reason
            self?.onChange?()
        }
    }

    func read() async throws -> SwitchSnapshot {
        if isEnabled, !backend.isHealthy {
            stop()
            failure = "输入拦截已失效，清洁模式已自动退出。"
        }
        if let reason = backend.unavailabilityReason {
            return SwitchSnapshot(isEnabled: false, detail: reason, availability: .unsupported(reason))
        }
        return SwitchSnapshot(isEnabled: isEnabled, detail: failure ?? "仅移动指针，点击屏幕中央按钮退出")
    }

    func setEnabled(_ enabled: Bool) async throws -> SwitchSnapshot {
        guard !stopped else { throw SwitchFailure.failed("清洁服务已停止。") }
        if enabled, !isEnabled {
            if let reason = backend.unavailabilityReason { throw SwitchFailure.unsupported(reason) }
            guard session == nil else { throw SwitchFailure.failed("清洁模式仍在启动。") }
            let token = UUID()
            session = token
            failure = nil
            // Suppress our Carbon handlers before creating any windows.
            onSessionChange?(true)
            do {
                try await backend.start()
                guard !stopped, session == token else { throw SwitchFailure.failed("清洁模式启动已取消。") }
                guard backend.isHealthy else { throw SwitchFailure.failed("无法确认完整输入保护，未开启清洁模式。") }
                isEnabled = true
            } catch {
                if session == token {
                    session = nil
                    backend.stop()
                    onSessionChange?(false)
                }
                Logger(subsystem: "local.herman.MacSwitch", category: "Cleaning").error("Startup failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        } else if !enabled { stop() }
        return try await read()
    }

    private func stop() {
        session = nil
        backend.stop()
        isEnabled = false
        onSessionChange?(false)
        onChange?()
    }

    func shutdown() {
        stopped = true
        stop()
    }
}

@MainActor
final class AppKitCleaningBackend: CleaningBackend {
    var onFailure: (@MainActor (String) -> Void)?
    var onExit: (@MainActor () -> Void)?
    private let input: any CleaningInputBackend
    private let prototype: Bool
    private var windows: [NSWindow] = []
    private var priorWindows: [(NSWindow, Bool)] = []
    private var priorApplication: NSRunningApplication?
    private var priorPresentation: NSApplication.PresentationOptions?
    private var assertion: IOPMAssertionID?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var watchdog: Timer?
    private var running = false
    private var generation: UUID?
    private var starting = false
    private let logger = Logger(subsystem: "local.herman.MacSwitch", category: "Cleaning")

    init(input: any CleaningInputBackend = QuartzCleaningInputBackend(), prototype: Bool = false) {
        self.input = input
        self.prototype = prototype
        input.onFailure = { [weak self] reason in self?.fail(reason) }
        input.onExit = { [weak self] in self?.onExit?() }
    }

    var unavailabilityReason: String? {
        CleaningCompatibility.unavailability(build: CleaningCompatibility.systemBuild,
            hasCornerProtection: CleaningCompatibility.presentationOptions != nil, prototype: prototype)
    }

    var isHealthy: Bool {
        running && AXIsProcessTrusted() && input.isHealthy && NSApp.isActive
            && CleaningCompatibility.presentationOptions.map { NSApp.presentationOptions.isSuperset(of: $0) } == true
            && windows.count == NSScreen.screens.count && !windows.isEmpty
            && windows.allSatisfy { $0.isVisible && $0.screen != nil }
    }

    func start() async throws {
        guard !starting else { throw SwitchFailure.failed("清洁模式仍在启动。") }
        guard !running else { return }
        if let reason = unavailabilityReason { throw SwitchFailure.unsupported(reason) }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw SwitchFailure.unauthorized("清洁模式需要辅助功能权限。请在系统设置中允许 MacSwitch，然后重试。")
        }
        let token = UUID()
        generation = token
        starting = true
        defer { if generation == token { starting = false } }
        do {
            try input.start()
            var id: IOPMAssertionID = 0
            guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "MacSwitch - Cleaning" as CFString, &id) == kIOReturnSuccess else {
                throw SwitchFailure.failed("无法保持屏幕点亮，未开启清洁模式。")
            }
            assertion = id
            priorApplication = NSWorkspace.shared.frontmostApplication
            priorPresentation = NSApp.presentationOptions
            guard let protection = CleaningCompatibility.presentationOptions else {
                throw SwitchFailure.unsupported("当前系统缺少触发角保护。")
            }
            // Use a known-valid combination; preserve the original option set
            // verbatim for exit instead of mixing mutually exclusive hide flags.
            NSApp.presentationOptions = protection
            priorWindows = NSApp.windows.filter { $0.isVisible }.map { ($0, $0.isKeyWindow) }
            for (window, _) in priorWindows { window.orderOut(nil) }
            running = true
            try rebuildWindows()
            observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
                guard let self, self.running else { return }
                do { try self.rebuildWindows() } catch { self.fail(error.localizedDescription) }
            }
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification) { [weak self] in
                self?.fail("系统即将睡眠，清洁模式已退出。", restoringFocus: false)
            }
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification) { [weak self] in
                self?.fail("显示器已睡眠，清洁模式已退出。", restoringFocus: false)
            }
            observe(NotificationCenter.default, NSApplication.didResignActiveNotification) { [weak self] in
                self?.fail("前台保护已失效，清洁模式已自动退出。", restoringFocus: false)
            }
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) { [weak self] in
                self?.fail("检测到桌面空间变化，清洁模式已退出；当前手势保护未通过验证。", restoringFocus: false)
            }
            // Activation is asynchronous, especially for accessory apps. Each
            // continuation belongs to one transaction and cannot stop its successor.
            for _ in 0..<30 where generation == token && running && !NSApp.isActive {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard generation == token, running else { throw SwitchFailure.failed("清洁模式启动已取消。") }
            guard NSApp.isActive else { throw SwitchFailure.failed("无法取得前台触发角保护，未开启清洁模式。") }
            watchdog = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    if !self.isHealthy { self.fail("权限、输入拦截或前台保护已失效，清洁模式已自动退出。", restoringFocus: false) }
                }
            }
            if let watchdog { RunLoop.main.add(watchdog, forMode: .common) }
        } catch {
            if generation == token { stop() }
            throw error
        }
    }

    func stop() { stop(restoringFocus: true) }

    private func stop(restoringFocus: Bool) {
        if running || !windows.isEmpty {
            logger.info("Cleanup begin masks=\(self.windows.count) restoreFocus=\(restoringFocus)")
        }
        running = false
        generation = nil
        starting = false
        watchdog?.invalidate(); watchdog = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        input.replaceTargets([])
        // Remove the blackout before releasing interception. The accepted exit
        // mouse-up has already been swallowed by the independent input backend.
        retireWindows(windows)
        windows.removeAll()
        input.stop()
        if let assertion { IOPMAssertionRelease(assertion) }
        assertion = nil
        if let priorPresentation { NSApp.presentationOptions = priorPresentation }
        priorPresentation = nil
        let wasOurApplication = priorApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        CleaningWindowPresentation.restore(priorWindows, priorApplicationWasMacSwitch: wasOurApplication,
                                           restoringFocus: restoringFocus)
        if restoringFocus, !wasOurApplication {
            priorApplication?.activate(options: [])
        }
        self.priorApplication = nil
        priorWindows.removeAll()
        logger.info("Cleanup complete masks=0 assertionReleased=\(self.assertion == nil)")
    }

    private func rebuildWindows() throws {
        guard !NSScreen.screens.isEmpty else { throw SwitchFailure.failed("没有可遮罩的显示器，清洁模式已退出。") }
        let screens = NSScreen.screens
        let primaryTop = screens[0].frame.maxY
        input.replaceTargets([]) // a display change cancels any in-flight click
        var replacement: [NSWindow] = []
        var targets: [CleaningExitTarget] = []
        for screen in screens {
            let window = CleaningWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrame(screen.frame, display: true)
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.backgroundColor = .black
            window.appearance = NSAppearance(named: .darkAqua)
            window.isOpaque = true
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.isExcludedFromWindowsMenu = true
            window.animationBehavior = .none
            window.tabbingMode = .disallowed
            window.hidesOnDeactivate = false
            window.acceptsMouseMovedEvents = true
            window.title = "MacSwitch 清洁模式"
            let view = CleaningMaskView(frame: NSRect(origin: .zero, size: screen.frame.size))
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            let screenRect = window.convertToScreen(view.exitButtonRectInWindow)
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  screenRect.width > 0, screenRect.height > 0 else {
                retireWindows(replacement + [window])
                throw SwitchFailure.failed("无法定位显示器退出按钮，清洁模式已退出。")
            }
            targets.append(CleaningExitTarget(displayID: displayID,
                rect: CleaningCoordinates.quartzRect(fromAppKit: screenRect, primaryScreenTop: primaryTop)))
            window.orderFrontRegardless()
            replacement.append(window)
        }
        // Cover a newly attached screen before retiring previous masks.
        let old = windows
        windows = replacement
        input.replaceTargets(targets)
        if old.isEmpty { NSApp.activate(ignoringOtherApps: true) }
        if NSApp.isActive { windows.first?.makeKeyAndOrderFront(nil) }
        retireWindows(old)
        logger.info("Masks rebuilt screens=\(NSScreen.screens.count) masks=\(self.windows.count)")
    }

    /// Remove the backing content as well as ordering out: a sleeping display
    /// or an in-flight Spaces transition must not animate an old black mask.
    private func retireWindows(_ retired: [NSWindow]) {
        for window in retired {
            window.animationBehavior = .none
            window.ignoresMouseEvents = true
            window.alphaValue = 0
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
    }

    private func fail(_ reason: String, restoringFocus: Bool = true) {
        guard running else { return }
        logger.info("Ending session: \(reason, privacy: .public)")
        stop(restoringFocus: restoringFocus)
        onFailure?(reason)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let observer = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, observer))
    }
}

@MainActor
enum CleaningWindowPresentation {
    static func restore(_ windows: [(NSWindow, Bool)], priorApplicationWasMacSwitch: Bool,
                        restoringFocus: Bool) {
        for (window, wasKey) in windows {
            // A background app can still have an isKeyWindow. Restoring it as
            // key would activate its Space over the user's foreground app.
            if restoringFocus && priorApplicationWasMacSwitch && wasKey { window.makeKeyAndOrderFront(nil) }
            else { window.orderFront(nil) }
        }
    }
}

private final class CleaningWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
}

private final class CleaningMaskView: NSView {
    private let button = MouseOnlyCleaningButton(title: "退出清洁模式", target: nil, action: nil)
    var exitButtonRectInWindow: NSRect { button.convert(button.bounds, to: nil) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "屏幕键盘清洁")
        icon.contentTintColor = .white
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 46, weight: .regular)
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.controlSize = .large
        // The visual button never receives a forwarded click. Only the global
        // input whitelist can recognize a complete, consumed exit click.
        button.setAccessibilityIdentifier("cleaning.exit")
        let stack = NSStackView(views: [icon, button])
        stack.orientation = .vertical
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.heightAnchor.constraint(equalToConstant: 64),
            icon.widthAnchor.constraint(equalToConstant: 80),
            button.widthAnchor.constraint(equalToConstant: 180),
            button.heightAnchor.constraint(equalToConstant: 36)
        ])
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}
}

private final class MouseOnlyCleaningButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
}
