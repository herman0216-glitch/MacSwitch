import Testing
@testable import MacSwitch

struct VolumeLinkTests {
    @Test func newlyPlayingApplicationStartsAtCurrentOutputWithoutOverwritingExistingTarget() {
        var state = VolumeLinkState(outputVolume: 60)
        #expect(state.addApplication("wechat") == 60)
        state.setApplicationVolume(80, for: "wechat")
        #expect(state.addApplication("wechat") == 80)
        state.applySystemOutput(90, isMuted: false)
        #expect(state.addApplication("browser") == 90)
        #expect(state.outputVolume == 90)
    }

    @Test func planExampleClampsAndImmediatelyReverses() {
        var state = VolumeLinkState(outputVolume: 60)
        state.addApplication("wechat")
        state.addApplication("browser")
        state.setApplicationVolume(80, for: "wechat")
        state.setApplicationVolume(30, for: "browser")
        state.applySystemOutput(90, isMuted: false)
        #expect(state.applicationTargets == ["wechat": 100, "browser": 60])
        state.applySystemOutput(80, isMuted: false)
        #expect(state.applicationTargets == ["wechat": 90, "browser": 50])
    }

    @Test func bottomBoundaryAlsoReversesWithoutHiddenOffset() {
        var state = VolumeLinkState(outputVolume: 60)
        state.addApplication("quiet")
        state.addApplication("loud")
        state.setApplicationVolume(10, for: "quiet")
        state.setApplicationVolume(80, for: "loud")
        state.applySystemOutput(30, isMuted: false)
        #expect(state.applicationTargets == ["quiet": 0, "loud": 50])
        state.applySystemOutput(35, isMuted: false)
        #expect(state.applicationTargets == ["quiet": 5, "loud": 55])
    }

    @Test func independentAdjustmentDoesNotMoveParentOrSibling() {
        var state = VolumeLinkState(outputVolume: 60)
        state.addApplication("a")
        state.addApplication("b")
        state.setApplicationVolume(100, for: "a")
        #expect(state.outputVolume == 60)
        #expect(state.applicationTargets["b"] == 60)
        state.setApplicationVolume(0, for: "a")
        #expect(state.outputVolume == 60)
        #expect(state.applicationTargets["b"] == 60)
    }

    @Test func repeatedReadbacksAndMuteDoNotReapplyDelta() {
        var state = VolumeLinkState(outputVolume: 60)
        state.addApplication("a")
        state.setApplicationVolume(80, for: "a")
        state.applySystemOutput(90, isMuted: false)
        for _ in 0..<100 { state.applySystemOutput(90, isMuted: false) }
        state.applySystemOutput(90, isMuted: true)
        #expect(state.outputVolume == 90)
        #expect(state.applicationTargets["a"] == 100)
        #expect(state.isOutputSilent)
        state.applySystemOutput(90, isMuted: false)
        #expect(!state.isOutputSilent)
        #expect(state.applicationTargets["a"] == 100)
    }

    @Test func zeroIsSilentButTargetsRemainEditableAndSaved() {
        var state = VolumeLinkState(outputVolume: 60)
        state.addApplication("a")
        state.setApplicationVolume(80, for: "a")
        state.applySystemOutput(0, isMuted: false)
        #expect(state.isOutputSilent)
        #expect(state.applicationTargets["a"] == 20)
        state.setApplicationVolume(75, for: "a")
        state.applySystemOutput(0, isMuted: true)
        #expect(state.applicationTargets["a"] == 75)
        state.applySystemOutput(10, isMuted: false)
        #expect(state.applicationTargets["a"] == 85)
    }

    @Test func rapidConfirmedChangesRespectEveryBoundaryAndDeduplicateEchoes() {
        var state = VolumeLinkState(outputVolume: 50)
        state.addApplication("a")
        state.setApplicationVolume(95, for: "a")
        for output in [70.0, 70, 60, 100, 90, 0, 0, 10, 9, 8, 20] {
            state.applySystemOutput(output, isMuted: false)
        }
        #expect(state.outputVolume == 20)
        #expect(state.applicationTargets["a"] == 20)
    }

    @Test func separateExternalReadbackUsesConfirmedValueNotRequestedValue() {
        var state = VolumeLinkState(outputVolume: 60)
        state.addApplication("a")
        state.setApplicationVolume(30, for: "a")
        // A requested 80 was quantized or superseded externally to 78.
        state.applySystemOutput(78, isMuted: false)
        #expect(state.applicationTargets["a"] == 48)
        state.applySystemOutput(78, isMuted: false)
        #expect(state.applicationTargets["a"] == 48)
    }

    @Test func resetClearsSessionAndRejectsNonFiniteUpdates() {
        var state = VolumeLinkState(outputVolume: 60)
        state.addApplication("a")
        state.setApplicationVolume(.nan, for: "a")
        state.applySystemOutput(.infinity, isMuted: true)
        #expect(state.applicationTargets["a"] == 60)
        #expect(state.outputVolume == 60)
        #expect(!state.isMuted)
        state.removeApplication("a")
        state.setApplicationVolume(80, for: "a")
        #expect(state.applicationTargets.isEmpty)
        state.addApplication("b")
        state.reset(outputVolume: 42, isMuted: true)
        #expect(state.applicationTargets.isEmpty)
        #expect(state.addApplication("b") == 42)
        #expect(state.isMuted)
    }

    @Test func percentagesAreClamped() {
        var state = VolumeLinkState(outputVolume: 200)
        #expect(state.outputVolume == 100)
        state.addApplication("a")
        state.setApplicationVolume(-50, for: "a")
        #expect(state.applicationTargets["a"] == 0)
        state.setApplicationVolume(500, for: "a")
        #expect(state.applicationTargets["a"] == 100)
    }
}
