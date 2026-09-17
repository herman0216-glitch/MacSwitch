import Carbon
import XCTest
@testable import MacSwitch

@MainActor
final class HotKeyServiceTests: XCTestCase {
    private let first = RecordedShortcut(keyCode: 0, modifiers: UInt32(controlKey | optionKey))
    private let second = RecordedShortcut(keyCode: 1, modifiers: UInt32(controlKey | optionKey))

    func testNoDefaultRegistrationAndDuplicateRejected() throws {
        let registrar = FakeHotKeyRegistrar()
        let service = HotKeyService(registrar: registrar, onTrigger: { _ in })
        XCTAssertTrue(registrar.registrations.isEmpty)
        try service.register(first, for: .appearance)
        XCTAssertThrowsError(try service.register(first, for: .desktop)) { error in
            XCTAssertEqual(error as? HotKeyError, .duplicate(.appearance))
        }
        XCTAssertEqual(registrar.registrations.count, 1)
        service.shutdown()
    }

    func testFailedReplacementPreservesOriginalAndItsCallback() throws {
        let registrar = FakeHotKeyRegistrar()
        var fired: [FeatureID] = []
        let service = HotKeyService(registrar: registrar, onTrigger: { fired.append($0) })
        try service.register(first, for: .appearance)
        let originalID = try XCTUnwrap(registrar.registrations.keys.first)
        registrar.rejectNextRegistration = true
        XCTAssertThrowsError(try service.register(second, for: .appearance))
        XCTAssertEqual(registrar.registrations, [originalID: first])
        registrar.handler?(originalID)
        XCTAssertEqual(fired, [.appearance])
        XCTAssertTrue(registrar.unregistered.isEmpty)
        service.shutdown()
    }

    func testSuccessfulReplacementRegistersBeforeUnregistering() throws {
        let registrar = FakeHotKeyRegistrar()
        let service = HotKeyService(registrar: registrar, onTrigger: { _ in })
        try service.register(first, for: .appearance)
        try service.register(second, for: .appearance)
        XCTAssertEqual(registrar.events, ["register:1", "register:2", "unregister:1"])
        XCTAssertEqual(Array(registrar.registrations.values), [second])
        service.shutdown()
    }

    func testClearAndShutdownRemoveBindingsAndIgnoreStaleCallbacks() throws {
        let registrar = FakeHotKeyRegistrar()
        var fired: [FeatureID] = []
        let service = HotKeyService(registrar: registrar, onTrigger: { fired.append($0) })
        try service.register(first, for: .appearance)
        try service.register(second, for: .desktop)
        let callback = registrar.handler
        try service.register(nil, for: .appearance)
        callback?(1)
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(registrar.registrations.count, 1)
        service.shutdown()
        service.shutdown()
        XCTAssertTrue(registrar.registrations.isEmpty)
        XCTAssertEqual(registrar.shutdownCount, 1)
        callback?(2)
        XCTAssertTrue(fired.isEmpty)
        XCTAssertThrowsError(try service.register(first, for: .appearance))
    }

    func testRecordingCapturesExistingHotKeyWithoutTriggeringAndRestores() throws {
        let registrar = FakeHotKeyRegistrar()
        var fired: [FeatureID] = []
        var recorded: [RecordedShortcut] = []
        let service = HotKeyService(registrar: registrar, onTrigger: { fired.append($0) })
        try service.register(first, for: .appearance)
        let recordingID = HotKeyService.beginRecording { recorded.append($0) }
        defer { HotKeyService.endRecording(recordingID); service.shutdown() }
        registrar.handler?(1)
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(recorded, [first])
        HotKeyService.endRecording(recordingID)
        registrar.handler?(1)
        XCTAssertEqual(fired, [.appearance])
    }

    func testValidationRejectsBareModifierAndSystemCombinations() {
        for shortcut in [
            RecordedShortcut(keyCode: 0, modifiers: UInt32(shiftKey)),
            RecordedShortcut(keyCode: 55, modifiers: UInt32(cmdKey)),
            RecordedShortcut(keyCode: 12, modifiers: UInt32(cmdKey)),
            RecordedShortcut(keyCode: 49, modifiers: UInt32(controlKey)),
            RecordedShortcut(keyCode: 53, modifiers: UInt32(cmdKey | optionKey))
        ] {
            XCTAssertThrowsError(try shortcut.validate())
        }
        XCTAssertNoThrow(try first.validate())
    }

    func testCleaningSuspendsBindingsAndRecorderWithoutLosingRegistration() throws {
        let registrar = FakeHotKeyRegistrar()
        var fired: [FeatureID] = []
        let service = HotKeyService(registrar: registrar, onTrigger: { fired.append($0) })
        try service.register(first, for: .appearance)
        service.isSuspended = true
        registrar.handler?(1)
        XCTAssertTrue(fired.isEmpty)
        XCTAssertEqual(registrar.registrations.count, 1)
        service.isSuspended = false
        XCTAssertEqual(registrar.resetPressedCount, 2)
        registrar.handler?(1)
        XCTAssertEqual(fired, [.appearance])
        service.shutdown()
    }
}

@MainActor
private final class FakeHotKeyRegistrar: HotKeyRegistering {
    var registrations: [UInt32: RecordedShortcut] = [:]
    var unregistered: [UInt32] = []
    var events: [String] = []
    var rejectNextRegistration = false
    var shutdownCount = 0
    var resetPressedCount = 0
    var handler: (@MainActor (UInt32) -> Void)?

    func installHandler(_ handler: @escaping @MainActor (UInt32) -> Void) throws { self.handler = handler }

    func register(_ shortcut: RecordedShortcut, identifier: UInt32) throws {
        if rejectNextRegistration {
            rejectNextRegistration = false
            throw HotKeyError.registrationFailed(-9878)
        }
        events.append("register:\(identifier)")
        registrations[identifier] = shortcut
    }

    func unregister(identifier: UInt32) {
        events.append("unregister:\(identifier)")
        unregistered.append(identifier)
        registrations.removeValue(forKey: identifier)
    }

    func resetPressedKeys() { resetPressedCount += 1 }

    func shutdown() {
        shutdownCount += 1
        registrations.removeAll()
        handler = nil
    }
}
