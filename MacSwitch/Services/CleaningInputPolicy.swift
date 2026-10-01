import CoreGraphics

/// All rectangles and points use Quartz global display points (not pixels).
struct CleaningExitTarget: Equatable {
    let displayID: UInt32
    let rect: CGRect
}

enum CleaningInputDecision: Equatable {
    case pass, discard, exit
}

/// Pure input whitelist. An exit consumes BOTH halves of the click. Leaving a
/// button cancels the click permanently, even if the pointer later returns.
struct CleaningInputPolicy {
    private(set) var targets: [CleaningExitTarget] = []
    private var pressedTarget: UInt32?
    private var leftIsDown = false
    private var exitPending = false

    mutating func replaceTargets(_ targets: [CleaningExitTarget]) {
        self.targets = targets
        pressedTarget = nil
        leftIsDown = false
    }

    mutating func reset() {
        targets = []
        pressedTarget = nil
        leftIsDown = false
        exitPending = false
    }

    mutating func decide(type: UInt32, point: CGPoint) -> CleaningInputDecision {
        guard !exitPending else { return .discard }
        switch type {
        case CGEventType.mouseMoved.rawValue:
            cancelIfOutside(point)
            return .pass
        case CGEventType.leftMouseDown.rawValue:
            // Duplicate downs cannot re-arm a cancelled drag.
            if !leftIsDown { pressedTarget = target(at: point)?.displayID }
            leftIsDown = true
        case CGEventType.leftMouseUp.rawValue:
            let shouldExit = leftIsDown && pressedTarget != nil && target(at: point)?.displayID == pressedTarget
            leftIsDown = false
            pressedTarget = nil
            if shouldExit { exitPending = true; return .exit }
        case CGEventType.leftMouseDragged.rawValue:
            cancelIfOutside(point)
        default:
            // Includes right/other buttons, scroll, keyboard, private gestures
            // and unknown future event types. None can activate a control.
            pressedTarget = nil
        }
        return .discard
    }

    private func target(at point: CGPoint) -> CleaningExitTarget? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        return targets.first { $0.rect.contains(point) }
    }

    private mutating func cancelIfOutside(_ point: CGPoint) {
        if let pressedTarget, target(at: point)?.displayID != pressedTarget { self.pressedTarget = nil }
    }
}

enum CleaningCoordinates {
    /// NSScreen.screens[0] owns the menu bar and defines the AppKit/Quartz
    /// origin. NSScreen.main follows keyboard focus and must NOT be used.
    static func quartzRect(fromAppKit rect: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryScreenTop - rect.maxY, width: rect.width, height: rect.height)
    }
}
