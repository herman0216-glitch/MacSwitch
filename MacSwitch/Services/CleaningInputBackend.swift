import AppKit
@preconcurrency import ApplicationServices

@MainActor
protocol CleaningInputBackend: AnyObject {
    var onFailure: (@MainActor (String) -> Void)? { get set }
    var onExit: (@MainActor () -> Void)? { get set }
    var isHealthy: Bool { get }
    func start() throws
    func replaceTargets(_ targets: [CleaningExitTarget])
    func stop()
}

enum CleaningTapKind: CaseIterable {
    case keyboard, session
    var location: CGEventTapLocation { self == .keyboard ? .cghidEventTap : .cgSessionEventTap }
    var requiredMask: CGEventMask {
        if self == .keyboard { return Self.keyboardMask }
        let pointerTypes: [CGEventType] = [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .mouseMoved, .leftMouseDragged, .rightMouseDragged, .scrollWheel,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        return pointerTypes.reduce(CleaningGestureCompatibility.requiredMask | Self.keyboardMask) { $0 | (1 << $1.rawValue) }
    }
    var requestedMask: CGEventMask { self == .keyboard ? Self.keyboardMask : .max }
    // Raw Quartz system-defined events include media keys; not an NSEvent cast.
    static let keyboardMask: CGEventMask = [UInt32(10), 11, 12, 14].reduce(0) { $0 | (1 << $1) }
}

@MainActor
protocol CleaningEventTap: AnyObject {
    var isHealthy: Bool { get }
    func start() throws
    func stop()
}

@MainActor
final class QuartzCleaningInputBackend: CleaningInputBackend {
    typealias TapFactory = @MainActor (CleaningTapKind, @escaping @MainActor (UInt32, CGPoint, Int64) -> Bool) -> any CleaningEventTap
    var onFailure: (@MainActor (String) -> Void)?
    var onExit: (@MainActor () -> Void)?
    private let makeTap: TapFactory
    private var taps: [any CleaningEventTap] = []
    private var policy = CleaningInputPolicy()
    private var session: UUID?
    private var ending = false
    private var failed = false
    private(set) var eventCounts: [UInt32: Int] = [:]

    init(makeTap: @escaping TapFactory = { QuartzCleaningEventTap(kind: $0, filter: $1) }) {
        self.makeTap = makeTap
    }

    var isHealthy: Bool { session != nil && !failed && taps.count == 2 && taps.allSatisfy(\.isHealthy) }

    func start() throws {
        guard session == nil else { return }
        session = UUID()
        ending = false
        failed = false
        eventCounts = [:]
        do {
            for kind in CleaningTapKind.allCases {
                let tap = makeTap(kind) { [weak self] type, point, realType in
                    self?.filter(kind: kind, type: type, point: point, realType: realType) ?? false
                }
                taps.append(tap) // includes partially started taps in rollback
                try tap.start()
            }
            guard isHealthy else { throw SwitchFailure.failed("无法确认完整输入拦截，未开启清洁模式。") }
        } catch { stop(); throw error }
    }

    func replaceTargets(_ targets: [CleaningExitTarget]) { policy.replaceTargets(targets) }

    func stop() {
        session = nil
        ending = false
        failed = false
        for tap in taps.reversed() { tap.stop() }
        taps = []
        policy.reset()
    }

    /// Returns true to swallow. No AppKit teardown occurs inside a CG callback;
    /// the consumed mouse-up is returned to WindowServer before masks disappear.
    private func filter(kind: CleaningTapKind, type: UInt32, point: CGPoint, realType: Int64) -> Bool {
        guard let token = session else { return false }
        if type == CGEventType.tapDisabledByTimeout.rawValue || type == CGEventType.tapDisabledByUserInput.rawValue {
            guard !ending else { return false }
            ending = true
            failed = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session == token else { return }
                self.onFailure?("输入拦截已被系统停用，清洁模式已自动退出。")
            }
            return false
        }
        guard !ending else { return true }
        eventCounts[type, default: 0] += 1
        if kind == .keyboard { return true }
        let effectiveType = CleaningGestureCompatibility.isPrivateGesture(callbackType: type, realType: realType)
            ? CleaningGestureCompatibility.gesture : type
        switch policy.decide(type: effectiveType, point: point) {
        case .pass: return false
        case .discard: return true
        case .exit:
            ending = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.session == token else { return }
                self.onExit?()
            }
            return true
        }
    }
}

@MainActor
private final class QuartzCleaningEventTap: CleaningEventTap {
    let kind: CleaningTapKind
    let filter: @MainActor (UInt32, CGPoint, Int64) -> Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tapID: UInt32?

    init(kind: CleaningTapKind, filter: @escaping @MainActor (UInt32, CGPoint, Int64) -> Bool) {
        self.kind = kind
        self.filter = filter
    }

    var isHealthy: Bool {
        guard let tap, CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap), let tapID,
              let entries = try? Self.tapList() else { return false }
        return entries.contains { $0.eventTapID == tapID && matches($0) }
    }

    func start() throws {
        let existing = Set(try Self.tapList().map(\.eventTapID))
        guard let port = CGEvent.tapCreate(tap: kind.location, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: kind.requestedMask,
            callback: cleaningInputCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            throw SwitchFailure.unauthorized("无法建立完整输入拦截，请检查 MacSwitch 的辅助功能权限。")
        }
        tap = port
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            throw SwitchFailure.failed("无法启动输入拦截事件循环。")
        }
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tapID = try Self.tapList().first { !existing.contains($0.eventTapID) && matches($0) }?.eventTapID
        guard isHealthy else { throw SwitchFailure.failed("系统未授予必需的键盘、鼠标或手势拦截范围。") }
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        tap = nil
        tapID = nil
    }

    private func matches(_ item: CGEventTapInformation) -> Bool {
        item.tappingProcess == getpid() && item.tapPoint == kind.location && item.enabled
            && item.options == .defaultTap && item.eventsOfInterest & kind.requiredMask == kind.requiredMask
    }

    private static func tapList() throws -> [CGEventTapInformation] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else { throw SwitchFailure.failed("无法核对输入拦截范围。") }
        // Spare entries avoid losing our newly installed tap if another process
        // installs one between the count and list calls. The API bounds writes.
        let capacity = count + 16
        var entries = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(capacity))
        let result = entries.withUnsafeMutableBufferPointer { CGGetEventTapList(capacity, $0.baseAddress, &count) }
        guard result == .success, count <= capacity else { throw SwitchFailure.failed("无法核对输入拦截范围。") }
        return Array(entries.prefix(Int(count)))
    }
}

private func cleaningInputCallback(_ proxy: CGEventTapProxy, _ type: CGEventType,
                                  _ event: CGEvent, _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    let owner = Unmanaged<QuartzCleaningEventTap>.fromOpaque(info).takeUnretainedValue()
    let point = event.location
    let realType = event.getIntegerValueField(CleaningGestureCompatibility.realTypeField)
    let discard = MainActor.assumeIsolated {
        owner.filter(type.rawValue, point, realType)
    }
    return discard ? nil : Unmanaged.passUnretained(event)
}
