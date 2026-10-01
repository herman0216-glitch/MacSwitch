import Foundation

@main struct ProbeLogicTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            count += 1
        }
        check(ProbePolicy.permitsMutation(build: "26A434"), "development build")
        check(!ProbePolicy.permitsMutation(build: "26A428"), "old build is not admitted")
        check(!ProbePolicy.permitsMutation(build: "unknown"), "unknown build is blocked")
        check(!ProbePolicy.permitsMutation(build: "26A435"), "future build is blocked")
        check(ProbePolicy.validHelper(targetPID: 2, observedPID: 2, targetConnection: 3,
                                     observedConnection: 3, controllerPID: 1), "helper identity")
        check(!ProbePolicy.validHelper(targetPID: 2, observedPID: 4, targetConnection: 3,
                                      observedConnection: 3, controllerPID: 1), "reused PID")
        check(!ProbePolicy.validHelper(targetPID: 2, observedPID: 2, targetConnection: 3,
                                      observedConnection: 4, controllerPID: 1), "changed window owner")
        check(!ProbePolicy.validHelper(targetPID: 1, observedPID: 1, targetConnection: 3,
                                      observedConnection: 3, controllerPID: 1), "same process is not a foreign test")
        let rect = [0.0, 0, 1920, 1080]
        check(ProbePolicy.isDesktopCandidate(verifiedFinder: true, layer: -10, desktopLayer: -10,
                                            bounds: rect, display: rect), "desktop candidate")
        check(!ProbePolicy.isDesktopCandidate(verifiedFinder: false, layer: -10, desktopLayer: -10,
                                             bounds: rect, display: rect), "name alone is insufficient")
        check(!ProbePolicy.isDesktopCandidate(verifiedFinder: true, layer: 0, desktopLayer: -10,
                                             bounds: rect, display: rect), "ordinary Finder window")
        check(!ProbePolicy.isDesktopCandidate(verifiedFinder: true, layer: -10, desktopLayer: -10,
                                             bounds: [1920, 0, 1920, 1080], display: rect), "wrong display")
        check(!ProbePolicy.isDesktopCandidate(verifiedFinder: true, layer: -10, desktopLayer: -10,
                                             bounds: [], display: rect), "missing geometry")
        let original = WindowState(alpha: 1, ordered: 1, alphaError: 0, orderError: 0)
        check(original.matches(original), "verified restore")
        check(!WindowState(alpha: 1, ordered: 1, alphaError: 1001, orderError: 0).matches(original),
              "read error cannot count as restored")
        check(!WindowState(alpha: 0, ordered: 1, alphaError: 0, orderError: 0).matches(original), "partial restore")
        check(!WindowState(alpha: 0, ordered: 1, alphaError: 0, orderError: 0).hidden,
              "alpha alone cannot count as safely hidden")
        check(WindowState(alpha: 0, ordered: 0, alphaError: 0, orderError: 0).hidden, "ordered-out test state")
        check(WindowState(alpha: 1, ordered: 0, alphaError: 0, orderError: 0).hidden,
              "AppKit resetting alpha does not order a removed window back in")
        check(foreignControlStatus(original: original, observations: [original], ownerBeforeRestore: original,
                                   environmentPreserved: true) == "NO_GO_DIRECT_CROSS_PROCESS_CONTROL",
              "success return without state change must not pass feasibility")
        check(foreignControlStatus(original: original, observations: [], ownerBeforeRestore: original,
                                   environmentPreserved: true) == "INCOMPLETE_REQUIRES_REVIEW", "missing evidence")
        check(foreignControlStatus(original: original, observations: [original], ownerBeforeRestore: original,
                                   environmentPreserved: false) == "INCOMPLETE_REQUIRES_REVIEW", "changed environment")
        check(foreignControlStatus(original: original,
                                   observations: [WindowState(alpha: 0, ordered: 0, alphaError: 0, orderError: 0)],
                                   ownerBeforeRestore: original, environmentPreserved: true) == "INCOMPLETE_REQUIRES_REVIEW",
              "changed foreign window still needs real recovery and physical acceptance")
        print("PASS: \(count) probe safety checks")
    }
}
