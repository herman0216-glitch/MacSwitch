import AppKit
@preconcurrency import ApplicationServices
import IOKit.pwr_mgt
import OSLog

@MainActor
protocol CleaningBackend: AnyObject {
    var onFailure: (@MainActor (String) -> Void)? { get set }
    var onExit: (@MainActor () -> Void)? { get set }
    var isHealthy: Bool { get }
    func start() throws
    func stop()
}

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
        return SwitchSnapshot(isEnabled: isEnabled, detail: failure ?? "黑屏清洁，点击屏幕中央按钮退出")
    }

    func setEnabled(_ enabled: Bool) async throws -> SwitchSnapshot {
        guard !stopped else { throw SwitchFailure.failed("清洁服务已停止。") }
        if enabled, !isEnabled {
            failure = nil
            // Suppress our Carbon handlers before creating any windows.
            onSessionChange?(true)
            do {
                try backend.start()
                guard backend.isHealthy else { throw SwitchFailure.failed("无法确认键盘拦截，未开启清洁模式。") }
                isEnabled = true
            } catch {
                backend.stop()
                onSessionChange?(false)
                Logger(subsystem: "local.herman.MacSwitch", category: "Cleaning").error("Startup failed: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        } else if !enabled { stop() }
        return try await read()
    }

    private func stop() {
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
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var windows: [NSWindow] = []
    private var priorWindows: [(NSWindow, Bool)] = []
    private var priorApplication: NSRunningApplication?
    private var priorPresentation: NSApplication.PresentationOptions?
    private var assertion: IOPMAssertionID?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var watchdog: Timer?
    private var running = false
    private let logger = Logger(subsystem: "local.herman.MacSwitch", category: "Cleaning")

    // NSEvent.systemDefined == 14 includes the media keys delivered to Quartz.
    static let blockedTypes: Set<UInt32> = [CGEventType.keyDown.rawValue,
        CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, 14]
    static let eventMask = blockedTypes.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1) }

    var isHealthy: Bool {
        running && AXIsProcessTrusted() && tap.map { CFMachPortIsValid($0) && CGEvent.tapIsEnabled(tap: $0) } == true
            && windows.count == NSScreen.screens.count && !windows.isEmpty
    }

    func start() throws {
        guard !running else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else {
            throw SwitchFailure.unauthorized("清洁模式需要辅助功能权限。请在系统设置中允许 MacSwitch，然后重试。")
        }
        do {
            let context = Unmanaged.passUnretained(self).toOpaque()
            guard let newTap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                options: .defaultTap, eventsOfInterest: Self.eventMask,
                callback: cleaningEventCallback, userInfo: context) else {
                throw SwitchFailure.unauthorized("无法建立主动键盘拦截。请检查辅助功能权限后重试。")
            }
            tap = newTap
            guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
                throw SwitchFailure.failed("无法启动键盘拦截事件循环。")
            }
            source = newSource
            CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
            CGEvent.tapEnable(tap: newTap, enable: true)
            guard CGEvent.tapIsEnabled(tap: newTap) else { throw SwitchFailure.failed("键盘拦截未启用。") }
            try verifyEventMask()
            var id: IOPMAssertionID = 0
            guard IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn), "MacSwitch - Cleaning" as CFString, &id) == kIOReturnSuccess else {
                throw SwitchFailure.failed("无法保持屏幕点亮，未开启清洁模式。")
            }
            assertion = id
            priorApplication = NSWorkspace.shared.frontmostApplication
            priorPresentation = NSApp.presentationOptions
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
            watchdog = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.running else { return }
                    if !self.isHealthy { self.fail("权限或输入拦截已失效，清洁模式已自动退出。") }
                }
            }
            if let watchdog { RunLoop.main.add(watchdog, forMode: .common) }
        } catch { stop(); throw error }
    }

    func stop() { stop(restoringFocus: true) }

    private func stop(restoringFocus: Bool) {
        if running || !windows.isEmpty {
            logger.info("Cleanup begin masks=\(self.windows.count) restoreFocus=\(restoringFocus)")
        }
        running = false
        watchdog?.invalidate(); watchdog = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        // Remove the blackout before releasing keyboard interception.
        retireWindows(windows)
        windows.removeAll()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
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
        logger.info("Cleanup complete masks=0 tapReleased=\(self.tap == nil) assertionReleased=\(self.assertion == nil)")
    }

    private func rebuildWindows() throws {
        guard !NSScreen.screens.isEmpty else { throw SwitchFailure.failed("没有可遮罩的显示器，清洁模式已退出。") }
        var replacement: [NSWindow] = []
        for screen in NSScreen.screens {
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
            view.exit = { [weak self] in self?.onExit?() }
            window.contentView = view
            window.orderFrontRegardless()
            replacement.append(window)
        }
        // Cover a newly attached screen before retiring previous masks.
        let old = windows
        windows = replacement
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
        logger.info("Ending session: \(reason, privacy: .public)")
        stop(restoringFocus: restoringFocus)
        onFailure?(reason)
    }

    private func verifyEventMask() throws {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else {
            throw SwitchFailure.failed("无法核对输入拦截范围，未开启清洁模式。")
        }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        let result = taps.withUnsafeMutableBufferPointer { CGGetEventTapList(count, $0.baseAddress, &count) }
        for item in taps.prefix(Int(count)) where item.tappingProcess == getpid() {
            Logger(subsystem: "local.herman.MacSwitch", category: "Cleaning").info("tap enabled=\(item.enabled) mask=\(item.eventsOfInterest) expected=\(Self.eventMask)")
        }
        guard result == .success, taps.prefix(Int(count)).contains(where: {
            $0.tappingProcess == getpid() && $0.enabled && $0.options == .defaultTap
                && $0.eventsOfInterest & Self.eventMask == Self.eventMask
        }) else {
            throw SwitchFailure.failed("系统未授予完整的键盘拦截范围，未开启清洁模式。")
        }
    }

    fileprivate func filterEvent(_ type: CGEventType) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            fail("输入拦截已被系统停用，清洁模式已自动退出。")
            return false
        }
        return Self.blockedTypes.contains(type.rawValue)
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

// The CFMachPort source is installed exclusively on the main run loop.
private func cleaningEventCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
    _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<AppKitCleaningBackend>.fromOpaque(info).takeUnretainedValue()
    let discard = MainActor.assumeIsolated { owner.filterEvent(type) }
    return discard ? nil : Unmanaged.passUnretained(event)
}

private final class CleaningWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
}

private final class CleaningMaskView: NSView {
    var exit: (() -> Void)?
    private let button = MouseOnlyCleaningButton(title: "退出清洁模式", target: nil, action: nil)

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
        button.target = self
        button.action = #selector(exitClicked)
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
    @objc private func exitClicked() { exit?() }
}

private final class MouseOnlyCleaningButton: NSButton {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
    override func keyDown(with event: NSEvent) {}
    override func keyUp(with event: NSEvent) {}
}
