import AppKit
import Testing
@testable import MacSwitch

struct CleaningInputPolicyTests {
    private let inside = CGPoint(x: 150, y: 120)
    private let outside = CGPoint(x: 10, y: 10)
    private var policy: CleaningInputPolicy {
        var value = CleaningInputPolicy()
        value.replaceTargets([
            CleaningExitTarget(displayID: 1, rect: CGRect(x: 100, y: 100, width: 180, height: 36)),
            CleaningExitTarget(displayID: 2, rect: CGRect(x: -900, y: -500, width: 180, height: 36))
        ])
        return value
    }

    @Test func onlyUnpressedPointerMovementPassesWhitelist() {
        for raw in UInt32(0)..<64 {
            var subject = policy
            let result = subject.decide(type: raw, point: outside)
            #expect(result == (raw == CGEventType.mouseMoved.rawValue ? .pass : .discard))
        }
    }

    @Test func bothHalvesAreConsumedAndExitIsEmittedOnce() {
        var subject = policy
        #expect(subject.decide(type: CGEventType.leftMouseDown.rawValue, point: inside) == .discard)
        #expect(subject.decide(type: CGEventType.leftMouseUp.rawValue, point: inside) == .exit)
        #expect(subject.decide(type: CGEventType.leftMouseUp.rawValue, point: inside) == .discard)
        #expect(subject.decide(type: CGEventType.mouseMoved.rawValue, point: inside) == .discard)
    }

    @Test func outsideClicksAndDragIntoButtonNeverExit() {
        var subject = policy
        #expect(subject.decide(type: CGEventType.leftMouseUp.rawValue, point: inside) == .discard)
        #expect(subject.decide(type: CGEventType.leftMouseDown.rawValue, point: outside) == .discard)
        #expect(subject.decide(type: CGEventType.leftMouseDragged.rawValue, point: inside) == .discard)
        #expect(subject.decide(type: CGEventType.leftMouseUp.rawValue, point: inside) == .discard)
    }

    @Test(arguments: [CGEventType.leftMouseDragged.rawValue, CGEventType.mouseMoved.rawValue])
    func leavingAndReturningPermanentlyCancelsClick(moveType: UInt32) {
        var subject = policy
        _ = subject.decide(type: CGEventType.leftMouseDown.rawValue, point: inside)
        _ = subject.decide(type: moveType, point: outside)
        _ = subject.decide(type: moveType, point: inside)
        // A duplicate down must not resurrect the cancelled drag.
        _ = subject.decide(type: CGEventType.leftMouseDown.rawValue, point: inside)
        #expect(subject.decide(type: CGEventType.leftMouseUp.rawValue, point: inside) == .discard)
    }

    @Test func changingScreenOrGeometryCancelsAnInFlightClick() {
        var subject = policy
        let external = CGPoint(x: -850, y: -480)
        _ = subject.decide(type: CGEventType.leftMouseDown.rawValue, point: inside)
        #expect(subject.decide(type: CGEventType.leftMouseUp.rawValue, point: external) == .discard)
        _ = subject.decide(type: CGEventType.leftMouseDown.rawValue, point: external)
        subject.replaceTargets(subject.targets)
        #expect(subject.decide(type: CGEventType.leftMouseUp.rawValue, point: external) == .discard)
        _ = subject.decide(type: CGEventType.leftMouseDown.rawValue, point: external)
        #expect(subject.decide(type: CGEventType.leftMouseUp.rawValue, point: external) == .exit)
    }

    @Test func gestureOrOtherButtonCancelsCandidate() {
        for type in [UInt32(29), 30, CGEventType.rightMouseDown.rawValue, CGEventType.scrollWheel.rawValue] {
            var subject = policy
            _ = subject.decide(type: CGEventType.leftMouseDown.rawValue, point: inside)
            #expect(subject.decide(type: type, point: inside) == .discard)
            #expect(subject.decide(type: CGEventType.leftMouseUp.rawValue, point: inside) == .discard)
        }
    }

    @Test func resetCannotLeaveStaleExitOrTargets() {
        var subject = policy
        _ = subject.decide(type: CGEventType.leftMouseDown.rawValue, point: inside)
        _ = subject.decide(type: CGEventType.leftMouseUp.rawValue, point: inside)
        subject.reset()
        #expect(subject.targets.isEmpty)
        #expect(subject.decide(type: CGEventType.mouseMoved.rawValue, point: inside) == .pass)
        #expect(subject.decide(type: CGEventType.leftMouseUp.rawValue, point: inside) == .discard)
    }

    @Test func coordinatesHandlePrimaryLeftAboveAndBelowDisplaysInPoints() {
        let primary = CleaningCoordinates.quartzRect(fromAppKit: CGRect(x: 630, y: 420, width: 180, height: 36), primaryScreenTop: 900)
        #expect(primary == CGRect(x: 630, y: 444, width: 180, height: 36))
        let leftAbove = CleaningCoordinates.quartzRect(fromAppKit: CGRect(x: -1800, y: 1100, width: 180, height: 36), primaryScreenTop: 900)
        #expect(leftAbove == CGRect(x: -1800, y: -236, width: 180, height: 36))
        let below = CleaningCoordinates.quartzRect(fromAppKit: CGRect(x: 2100, y: -500, width: 180, height: 36), primaryScreenTop: 900)
        #expect(below == CGRect(x: 2100, y: 1364, width: 180, height: 36))
    }

    @Test func buildGateRequiresAdmissionAndCornerProtection() {
        #expect(CleaningCompatibility.unavailability(build: "future-build", hasCornerProtection: true) != nil)
        #expect(CleaningCompatibility.unavailability(build: "26A428", hasCornerProtection: false, prototype: true) != nil)
        #expect(CleaningCompatibility.unavailability(build: "26A428", hasCornerProtection: true) == nil)
        #expect(CleaningCompatibility.unavailability(build: "26A434", hasCornerProtection: true) == nil)
        #expect(CleaningCompatibility.unavailability(build: "26A434", hasCornerProtection: false) != nil)
        #expect(CleaningCompatibility.unavailability(build: "26A435", hasCornerProtection: true) != nil)
        #expect(CleaningCompatibility.unavailability(build: "26A428", hasCornerProtection: true, verifiedBuilds: []) != nil)
        #expect(CleaningCompatibility.unavailability(build: "accepted-test-build", hasCornerProtection: true,
                                                     verifiedBuilds: ["accepted-test-build"]) == nil)
        #expect(CleaningCompatibility.unavailability(build: "accepted-test-build", hasCornerProtection: false,
                                                     verifiedBuilds: ["accepted-test-build"]) != nil)
        #expect(CleaningCompatibility.unavailability(build: "26A428", hasCornerProtection: true, prototype: true) == nil)
    }

    @Test func privateGestureCompatibilityDoesNotCastAppKitEventNumbers() {
        #expect(CleaningGestureCompatibility.isPrivateGesture(callbackType: 0, realType: 30))
        #expect(CleaningGestureCompatibility.isPrivateGesture(callbackType: 29, realType: 0))
        #expect(!CleaningGestureCompatibility.isPrivateGesture(callbackType: CGEventType.mouseMoved.rawValue, realType: 5))
        #expect(CleaningTapKind.session.requiredMask & CleaningGestureCompatibility.requiredMask == CleaningGestureCompatibility.requiredMask)
        #expect(CleaningTapKind.session.requestedMask == .max)
    }
}

@MainActor
struct CleaningInputBackendTests {
    @Test func partialTapStartupFailureRollsBackBothTapsAndRepeatedStopIsSafe() {
        var taps: [FakeCleaningEventTap] = []
        let backend = QuartzCleaningInputBackend { kind, callback in
            let tap = FakeCleaningEventTap(callback: callback)
            tap.failStartup = kind == .session
            taps.append(tap)
            return tap
        }
        #expect(throws: SwitchFailure.self) { try backend.start() }
        #expect(taps.count == 2)
        #expect(taps.allSatisfy { !$0.isHealthy && $0.stops == 1 })
        backend.stop()
        #expect(taps.allSatisfy { $0.stops == 1 })
        #expect(!backend.isHealthy)
    }

    @Test func eitherTapLossInvalidatesWholeSession() throws {
        var taps: [FakeCleaningEventTap] = []
        let backend = QuartzCleaningInputBackend { _, callback in
            let tap = FakeCleaningEventTap(callback: callback); taps.append(tap); return tap
        }
        try backend.start()
        #expect(backend.isHealthy)
        taps[0].isHealthy = false
        #expect(!backend.isHealthy)
        backend.stop()
        try backend.start()
        taps.last?.isHealthy = false
        #expect(!backend.isHealthy)
        backend.stop()
    }

    @Test func exitIsDeferredUntilAfterMouseUpWasSwallowed() async throws {
        var sessionTap: FakeCleaningEventTap?
        let backend = QuartzCleaningInputBackend { kind, callback in
            let tap = FakeCleaningEventTap(callback: callback)
            if kind == .session { sessionTap = tap }
            return tap
        }
        var exits = 0
        backend.onExit = { exits += 1; backend.stop() }
        try backend.start()
        backend.replaceTargets([CleaningExitTarget(displayID: 1, rect: CGRect(x: 100, y: 100, width: 100, height: 40))])
        let point = CGPoint(x: 120, y: 120)
        #expect(sessionTap?.callback(CGEventType.leftMouseDown.rawValue, point, 1) == true)
        #expect(sessionTap?.callback(CGEventType.leftMouseUp.rawValue, point, 2) == true)
        #expect(exits == 0)
        #expect(backend.isHealthy) // pending normal exit must not trip watchdog
        await settleCallbacks()
        #expect(exits == 1)
        #expect(!backend.isHealthy)
    }

    @Test func staleTimeoutCannotTerminateReplacementSession() async throws {
        var taps: [FakeCleaningEventTap] = []
        let backend = QuartzCleaningInputBackend { _, callback in
            let tap = FakeCleaningEventTap(callback: callback); taps.append(tap); return tap
        }
        var failures = 0
        backend.onFailure = { _ in failures += 1; backend.stop() }
        try backend.start()
        #expect(taps[0].callback(CGEventType.tapDisabledByTimeout.rawValue, .zero, 0) == false)
        backend.stop()
        try backend.start()
        await settleCallbacks()
        #expect(failures == 0)
        #expect(backend.isHealthy)
        #expect(taps.last?.callback(CGEventType.tapDisabledByUserInput.rawValue, .zero, 0) == false)
        await settleCallbacks()
        #expect(failures == 1)
        #expect(!backend.isHealthy)
    }

    private func settleCallbacks() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

@MainActor
private final class FakeCleaningEventTap: CleaningEventTap {
    let callback: @MainActor (UInt32, CGPoint, Int64) -> Bool
    var isHealthy = false
    var failStartup = false
    var stops = 0
    init(callback: @escaping @MainActor (UInt32, CGPoint, Int64) -> Bool) { self.callback = callback }
    func start() throws {
        isHealthy = true
        if failStartup { throw SwitchFailure.failed("tap start failed") }
    }
    func stop() { isHealthy = false; stops += 1 }
}
