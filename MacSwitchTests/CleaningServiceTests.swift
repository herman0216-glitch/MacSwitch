import AppKit
import Testing
@testable import MacSwitch

@MainActor
struct CleaningServiceTests {
    @Test func failedStartupRestoresHotkeysAndResources() async {
        let backend = FakeCleaningBackend()
        backend.error = SwitchFailure.unauthorized("denied")
        let service = CleaningService(backend: backend)
        var suspension: [Bool] = []
        service.onSessionChange = { suspension.append($0) }
        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
        #expect(suspension == [true, false])
        #expect(!service.isEnabled)
        #expect(backend.stops == 1)
    }

    @Test func buttonExitAndRevocationReleaseSession() async throws {
        let backend = FakeCleaningBackend()
        let service = CleaningService(backend: backend)
        #expect(try await service.setEnabled(true).isEnabled)
        backend.onExit?()
        #expect(!service.isEnabled)
        #expect(!backend.isHealthy)
        #expect(try await service.setEnabled(true).isEnabled)
        backend.onFailure?("permission revoked")
        let state = try await service.read()
        #expect(!state.isEnabled)
        #expect(state.detail == "permission revoked")
        #expect(backend.stops == 2)
    }

    @Test func healthLossAndShutdownNeverLeaveInputBlocked() async throws {
        let backend = FakeCleaningBackend()
        let service = CleaningService(backend: backend)
        _ = try await service.setEnabled(true)
        backend.isHealthy = false
        #expect(try await !service.read().isEnabled)
        _ = try await service.setEnabled(true)
        service.shutdown()
        #expect(!service.isEnabled)
        #expect(!backend.isHealthy)
        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
    }

    @Test func ordinaryModifiersAndMediaKeysAreIncluded() {
        for type in [CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue, 14] {
            #expect(AppKitCleaningBackend.eventMask & (1 << type) != 0)
        }
        #expect(AppKitCleaningBackend.eventMask & (1 << CGEventType.leftMouseDown.rawValue) == 0)
    }

    @Test func sleepRestoresVisibilityWithoutActivatingAnOldSpace() {
        let window = RestorationSpyWindow()
        CleaningWindowPresentation.restore([(window, true)], priorApplicationWasMacSwitch: true, restoringFocus: false)
        #expect(window.orderedFront == 1)
        #expect(window.madeKey == 0)
    }

    @Test func backgroundKeyWindowDoesNotStealForegroundApplicationOnExit() {
        let window = RestorationSpyWindow()
        CleaningWindowPresentation.restore([(window, true)], priorApplicationWasMacSwitch: false, restoringFocus: true)
        #expect(window.orderedFront == 1)
        #expect(window.madeKey == 0)
        CleaningWindowPresentation.restore([(window, true)], priorApplicationWasMacSwitch: true, restoringFocus: true)
        #expect(window.madeKey == 1)
    }
}

@MainActor
private final class RestorationSpyWindow: NSWindow {
    var orderedFront = 0
    var madeKey = 0
    init() {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        isReleasedWhenClosed = false
    }
    override func orderFront(_ sender: Any?) { orderedFront += 1 }
    override func makeKeyAndOrderFront(_ sender: Any?) { madeKey += 1 }
}

@MainActor
private final class FakeCleaningBackend: CleaningBackend {
    var onFailure: (@MainActor (String) -> Void)?
    var onExit: (@MainActor () -> Void)?
    var isHealthy = false
    var error: Error?
    var stops = 0
    func start() throws { if let error { throw error }; isHealthy = true }
    func stop() { isHealthy = false; stops += 1 }
}
