import AppKit
import ObjectiveC
import OSLog

enum AppearanceTransitionPolicy {
    static func isEnabled(build: String) -> Bool {
        // Explicit build admission; the driver still checks the Objective-C ABI.
        // 26A434 was enabled at the user's request, pending physical acceptance.
        build == "26A428" || build == "26A434"
    }
}

@MainActor
protocol AppearanceTransitionBackend: AnyObject {
    var isAvailable: Bool { get }
    func setDarkMode(_ enabled: Bool) async throws
    func shutdown()
}

@MainActor
protocol AppearanceTransitionDriver: AnyObject {
    func start(_ enabled: Bool, completion: @escaping @Sendable () -> Void) throws
    func releaseTransition()
}

/// A missing callback cannot retain the command queue forever. Completion, timeout,
/// cancellation and shutdown all compete for the same operation token.
@MainActor
final class NativeAppearanceTransitionBackend: AppearanceTransitionBackend {
    private let driver: any AppearanceTransitionDriver
    private let timeout: Duration
    private var continuation: CheckedContinuation<Void, Error>?
    private var operation: UUID?
    private var watchdog: Task<Void, Never>?
    private var usable = true
    private let logger = Logger(subsystem: "local.herman.MacSwitch", category: "Appearance")
    var isAvailable: Bool { usable }

    init(driver: any AppearanceTransitionDriver, timeout: Duration = .seconds(2)) {
        self.driver = driver
        self.timeout = timeout
    }

    static func systemBackend() -> NativeAppearanceTransitionBackend? {
        let build = SystemAppearanceTransitionDriver.systemBuild
        guard AppearanceTransitionPolicy.isEnabled(build: build),
              let driver = SystemAppearanceTransitionDriver() else { return nil }
        let backend = NativeAppearanceTransitionBackend(driver: driver)
        backend.logger.notice("Native appearance enabled, build=\(build, privacy: .public)")
        return backend
    }

    func setDarkMode(_ enabled: Bool) async throws {
        guard isAvailable else { throw SwitchFailure.unsupported("原生外观过渡未启用。") }
        guard operation == nil else { throw SwitchFailure.failed("外观过渡仍在进行中。") }
        try Task.checkCancellation()
        let token = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.continuation = continuation
                operation = token
                watchdog = Task { [weak self, timeout] in
                    do { try await Task.sleep(for: timeout) } catch { return }
                    self?.finish(token, error: SwitchFailure.failed("原生外观过渡回调超时。"))
                }
                do {
                    logger.info("Native appearance transition started")
                    try driver.start(enabled) { [weak self] in
                        Task { @MainActor in self?.finish(token, error: nil) }
                    }
                } catch { finish(token, error: error) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(token, error: CancellationError()) }
        }
    }

    private func finish(_ token: UUID, error: Error?) {
        guard operation == token else { return }
        let pending = continuation
        continuation = nil
        operation = nil
        watchdog?.cancel()
        watchdog = nil
        driver.releaseTransition()
        // A timed-out system operation may still finish later. Quarantine the native
        // backend for this session rather than starting another native transition.
        if let error {
            usable = false
            logger.error("Native appearance transition failed; disabled for this session")
            pending?.resume(throwing: error)
        } else {
            logger.info("Native appearance transition completed")
            pending?.resume()
        }
    }

    func shutdown() {
        usable = false
        if let operation { finish(operation, error: CancellationError()) }
    }
}

/// The app only instantiates this driver on an ABI-verified system build.
/// No screenshots, overlays, automatic-appearance writes or animation-duration tuning.
@MainActor
private final class SystemAppearanceTransitionDriver: AppearanceTransitionDriver {
    private typealias Factory = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
    private typealias Post = @convention(c) (AnyObject, Selector, UInt64, @escaping @convention(block) () -> Void) -> Void
    private let cls: AnyClass
    private let create: Factory
    private let post: Post
    private let set: @convention(c) (Bool, Bool) -> Void
    private let library: UnsafeMutableRawPointer
    private var transition: AnyObject?

    static var systemBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    init?() {
        guard let cls = NSClassFromString("NSGlobalPreferenceTransition"),
              let factory = class_getClassMethod(cls, NSSelectorFromString("transition")),
              let post = class_getInstanceMethod(cls, NSSelectorFromString("postChangeNotification:completionHandler:")),
              let factoryEncoding = method_getTypeEncoding(factory),
              let postEncoding = method_getTypeEncoding(post),
              String(cString: factoryEncoding) == "@16@0:8",
              String(cString: postEncoding) == "v32@0:8Q16@?24",
              let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY) else { return nil }
        guard let symbol = dlsym(library, "SLSSetAppearanceThemeNotifying") else {
            dlclose(library)
            return nil
        }
        self.cls = cls
        self.library = library
        create = unsafeBitCast(method_getImplementation(factory), to: Factory.self)
        self.post = unsafeBitCast(method_getImplementation(post), to: Post.self)
        set = unsafeBitCast(symbol, to: (@convention(c) (Bool, Bool) -> Void).self)
    }

    func start(_ enabled: Bool, completion: @escaping @Sendable () -> Void) throws {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Preserve the native setter while omitting the animated transition.
            set(enabled, true)
            completion()
            return
        }
        set(enabled, false)
        let transition = create(cls, NSSelectorFromString("transition")).takeUnretainedValue()
        self.transition = transition
        post(transition, NSSelectorFromString("postChangeNotification:completionHandler:"), 0, completion)
    }

    func releaseTransition() { transition = nil }
    isolated deinit { dlclose(library) }
}
