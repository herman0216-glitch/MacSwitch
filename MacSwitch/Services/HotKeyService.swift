import Carbon
import Foundation

@MainActor
protocol HotKeyRegistering: AnyObject {
    func installHandler(_ handler: @escaping @MainActor (UInt32) -> Void) throws
    func register(_ shortcut: RecordedShortcut, identifier: UInt32) throws
    func unregister(identifier: UInt32)
    func resetPressedKeys()
    func shutdown()
}

extension HotKeyRegistering { func resetPressedKeys() {} }

enum HotKeyError: Error, LocalizedError, Equatable {
    case duplicate(FeatureID)
    case registrationFailed(Int32)
    case eventHandlerFailed(Int32)
    case stopped

    var errorDescription: String? {
        switch self {
        case .duplicate(let feature): "此快捷键已用于“\(feature.title)”。"
        case .registrationFailed(let status): "无法注册此快捷键，它可能已被系统或其他应用占用（\(status)）。"
        case .eventHandlerFailed(let status): "无法启用全局快捷键（\(status)）。"
        case .stopped: "快捷键服务已停止。"
        }
    }
}

@MainActor
final class HotKeyService {
    private struct Binding {
        let shortcut: RecordedShortcut
        let identifier: UInt32
    }

    // Carbon consumes already registered keys before keyDown. Route these keys into
    // the active recorder instead of toggling a feature or silently losing the key.
    private static var recordingSession: (id: UUID, receive: @MainActor (RecordedShortcut) -> Void)?

    static var recorderSuspended: Bool { recordingSession != nil }

    static func beginRecording(_ receive: @escaping @MainActor (RecordedShortcut) -> Void) -> UUID {
        let id = UUID()
        recordingSession = (id, receive)
        return id
    }

    static func endRecording(_ id: UUID) {
        if recordingSession?.id == id { recordingSession = nil }
    }

    private let registrar: any HotKeyRegistering
    private let onTrigger: @MainActor (FeatureID) -> Void
    private var bindings: [FeatureID: Binding] = [:]
    private var nextIdentifier: UInt32 = 1
    private var setupError: Error?
    private var isStopped = false
    var isSuspended = false {
        didSet { if oldValue != isSuspended { registrar.resetPressedKeys() } }
    }

    convenience init(onTrigger: @escaping @MainActor (FeatureID) -> Void) {
        self.init(registrar: CarbonHotKeyRegistrar(), onTrigger: onTrigger)
    }

    init(registrar: any HotKeyRegistering, onTrigger: @escaping @MainActor (FeatureID) -> Void) {
        self.registrar = registrar
        self.onTrigger = onTrigger
        do {
            try registrar.installHandler { [weak self] identifier in
                self?.receive(identifier)
            }
        } catch {
            setupError = error
        }
    }

    func register(_ shortcut: RecordedShortcut?, for feature: FeatureID) throws {
        guard !isStopped else { throw HotKeyError.stopped }
        guard let shortcut else {
            if let old = bindings.removeValue(forKey: feature) {
                registrar.unregister(identifier: old.identifier)
            }
            return
        }
        try shortcut.validate()
        if let setupError { throw setupError }
        if bindings[feature]?.shortcut == shortcut { return }
        if let duplicate = bindings.first(where: { $0.key != feature && $0.value.shortcut == shortcut }) {
            throw HotKeyError.duplicate(duplicate.key)
        }
        let identifier = nextIdentifier
        nextIdentifier &+= 1
        if nextIdentifier == 0 { nextIdentifier = 1 }
        // Register first: if Carbon rejects the replacement, the original stays live.
        try registrar.register(shortcut, identifier: identifier)
        if let old = bindings[feature] { registrar.unregister(identifier: old.identifier) }
        bindings[feature] = Binding(shortcut: shortcut, identifier: identifier)
    }

    func shutdown() {
        guard !isStopped else { return }
        isStopped = true
        bindings.removeAll()
        registrar.shutdown()
    }

    isolated deinit { registrar.shutdown() }

    private func receive(_ identifier: UInt32) {
        guard !isStopped, !isSuspended,
              let binding = bindings.first(where: { $0.value.identifier == identifier }) else { return }
        if let recordingSession = Self.recordingSession {
            recordingSession.receive(binding.value.shortcut)
            return
        }
        onTrigger(binding.key)
    }
}

@MainActor
private final class CarbonHotKeyRegistrar: HotKeyRegistering {
    private static let signature: OSType = 0x4D535748 // MSWH
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var pressedIdentifiers: Set<UInt32> = []
    private var eventHandler: EventHandlerRef?
    private var handler: (@MainActor (UInt32) -> Void)?

    func installHandler(_ handler: @escaping @MainActor (UInt32) -> Void) throws {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var hotKey = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                          EventParamType(typeEventHotKeyID), nil,
                                          MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
            guard result == noErr, hotKey.signature == 0x4D535748 else { return OSStatus(eventNotHandledErr) }
            let identifier = hotKey.id
            let isPressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            // Application event handlers execute on the application's main event loop.
            return MainActor.assumeIsolated {
                let owner = Unmanaged<CarbonHotKeyRegistrar>.fromOpaque(context).takeUnretainedValue()
                if isPressed {
                    if owner.pressedIdentifiers.insert(identifier).inserted { owner.handler?(identifier) }
                } else {
                    owner.pressedIdentifiers.remove(identifier)
                }
                return noErr
            }
        }, eventTypes.count, &eventTypes, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else { throw HotKeyError.eventHandlerFailed(status) }
        self.handler = handler
    }

    func register(_ shortcut: RecordedShortcut, identifier: UInt32) throws {
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        // Non-exclusive registration lets several apps receive the same key.
        // Exclusive registration makes an existing owner a reportable conflict.
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else { throw HotKeyError.registrationFailed(status) }
        references[identifier] = reference
    }

    func unregister(identifier: UInt32) {
        pressedIdentifiers.remove(identifier)
        if let reference = references.removeValue(forKey: identifier) { UnregisterEventHotKey(reference) }
    }

    func resetPressedKeys() { pressedIdentifiers.removeAll() }

    func shutdown() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll()
        pressedIdentifiers.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        handler = nil
    }

    isolated deinit { shutdown() }
}
