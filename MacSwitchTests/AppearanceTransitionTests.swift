import Testing
@testable import MacSwitch

@MainActor
struct AppearanceTransitionTests {
    @Test func nativePathIsUsedOnlyOnAdmittedSystemBuilds() {
        #expect(AppearanceTransitionPolicy.isEnabled(build: "26A428"))
        #expect(AppearanceTransitionPolicy.isEnabled(build: "26A434"))
        #expect(!AppearanceTransitionPolicy.isEnabled(build: "26A429"))
        #expect(!AppearanceTransitionPolicy.isEnabled(build: "26A435"))
        #expect(!AppearanceTransitionPolicy.isEnabled(build: ""))
    }

    @Test func missingCallbackTimesOutAndLateCallbackIsHarmless() async {
        let driver = TransitionDriverSpy()
        let backend = NativeAppearanceTransitionBackend(driver: driver, timeout: .milliseconds(10))
        await #expect(throws: SwitchFailure.failed("原生外观过渡回调超时。")) {
            try await backend.setDarkMode(true)
        }
        #expect(!backend.isAvailable)
        #expect(driver.releaseCount == 1)
        driver.callbacks[0]()
        await Task.yield()
        #expect(driver.releaseCount == 1)
    }

    @Test func duplicateAndOldCallbacksCannotCompleteTheNextOperation() async throws {
        let driver = TransitionDriverSpy()
        let backend = NativeAppearanceTransitionBackend(driver: driver)
        let first = Task { try await backend.setDarkMode(true) }
        while driver.callbacks.count < 1 { await Task.yield() }
        driver.callbacks[0]()
        driver.callbacks[0]()
        try await first.value
        let second = Task { try await backend.setDarkMode(false) }
        while driver.callbacks.count < 2 { await Task.yield() }
        driver.callbacks[0]()
        await Task.yield()
        #expect(driver.releaseCount == 1)
        driver.callbacks[1]()
        try await second.value
        #expect(driver.releaseCount == 2)
        #expect(backend.isAvailable)
    }

    @Test func synchronousCallbackIsSafe() async throws {
        let driver = TransitionDriverSpy()
        driver.completeImmediately = true
        let backend = NativeAppearanceTransitionBackend(driver: driver)
        try await backend.setDarkMode(true)
        #expect(driver.releaseCount == 1)
    }

    @Test func startFailureReleasesResources() async {
        let driver = TransitionDriverSpy()
        driver.error = .failed("启动失败")
        let backend = NativeAppearanceTransitionBackend(driver: driver)
        await #expect(throws: SwitchFailure.failed("启动失败")) { try await backend.setDarkMode(true) }
        #expect(driver.releaseCount == 1)
        #expect(!backend.isAvailable)
    }

    @Test func shutdownResumesPendingOperationAndRejectsLateCallbacks() async {
        let driver = TransitionDriverSpy()
        let backend = NativeAppearanceTransitionBackend(driver: driver)
        let task = Task { try await backend.setDarkMode(true) }
        while driver.callbacks.isEmpty { await Task.yield() }
        backend.shutdown()
        await #expect(throws: CancellationError.self) { try await task.value }
        driver.callbacks[0]()
        await Task.yield()
        #expect(driver.releaseCount == 1)
        #expect(!backend.isAvailable)
    }

    @Test func cancellationReleasesPendingOperation() async {
        let driver = TransitionDriverSpy()
        let backend = NativeAppearanceTransitionBackend(driver: driver)
        let task = Task { try await backend.setDarkMode(true) }
        while driver.callbacks.isEmpty { await Task.yield() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(driver.releaseCount == 1)
        #expect(!backend.isAvailable)
    }

    @Test func overlappingNativeOperationIsRejected() async throws {
        let driver = TransitionDriverSpy()
        let backend = NativeAppearanceTransitionBackend(driver: driver)
        let task = Task { try await backend.setDarkMode(true) }
        while driver.callbacks.isEmpty { await Task.yield() }
        await #expect(throws: SwitchFailure.failed("外观过渡仍在进行中。")) {
            try await backend.setDarkMode(false)
        }
        #expect(driver.callbacks.count == 1)
        driver.callbacks[0]()
        try await task.value
    }
}

@MainActor
final class TransitionDriverSpy: AppearanceTransitionDriver {
    var callbacks: [@Sendable () -> Void] = []
    var releaseCount = 0
    var error: SwitchFailure?
    var completeImmediately = false
    var onStart: ((Bool) -> Void)?
    func start(_ enabled: Bool, completion: @escaping @Sendable () -> Void) throws {
        callbacks.append(completion)
        onStart?(enabled)
        if let error { throw error }
        if completeImmediately { completion() }
    }
    func releaseTransition() { releaseCount += 1 }
}
