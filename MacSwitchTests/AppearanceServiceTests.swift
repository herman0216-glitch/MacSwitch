import Testing
@testable import MacSwitch

@MainActor
struct AppearanceServiceTests {
    @Test func nativeSuccessReturnsConfirmedStateWithoutAutomation() async throws {
        let backend = MockAppearanceBackend()
        let driver = TransitionDriverSpy()
        driver.completeImmediately = true
        driver.onStart = { backend.darkMode = $0 }
        let service = AppearanceService(backend: backend, transitionBackend: NativeAppearanceTransitionBackend(driver: driver))
        defer { service.shutdown() }

        let result = try await service.setEnabled(true)
        #expect(result.isEnabled)
        #expect(result.availability == .available)
        #expect(backend.events == [.read])
        #expect(driver.callbacks.count == 1)
    }

    @Test(arguments: [false, true])
    func nativeTimeoutReadsBackWithoutRepeatingWrite(partiallyApplied: Bool) async throws {
        let backend = MockAppearanceBackend()
        let driver = TransitionDriverSpy()
        driver.onStart = { if partiallyApplied { backend.darkMode = $0 } }
        let native = NativeAppearanceTransitionBackend(driver: driver, timeout: .milliseconds(10))
        let service = AppearanceService(backend: backend, transitionBackend: native)
        defer { service.shutdown() }

        if partiallyApplied {
            #expect(try await service.setEnabled(true).isEnabled)
        } else {
            await #expect(throws: SwitchFailure.failed("原生外观过渡回调超时。")) {
                try await service.setEnabled(true)
            }
        }
        #expect(backend.darkMode == partiallyApplied)
        #expect(backend.events == [.read])
        #expect(!native.isAvailable)
        driver.callbacks[0]()
        await Task.yield()
        #expect(driver.releaseCount == 1)
    }

    @Test func unconfirmedNativeCallbackFailsAndQuarantinesBackend() async {
        let backend = MockAppearanceBackend()
        let driver = TransitionDriverSpy()
        driver.completeImmediately = true
        let native = NativeAppearanceTransitionBackend(driver: driver)
        let service = AppearanceService(backend: backend, transitionBackend: native)
        defer { service.shutdown() }

        await #expect(throws: SwitchFailure.failed("系统未确认外观变化，请刷新后重试。")) {
            try await service.setEnabled(true)
        }
        #expect(!native.isAvailable)
        #expect(!backend.darkMode)
        #expect(backend.events.count >= 15)
    }

    @Test func missingNativeInterfaceIsUnsupportedWithoutAutomation() async throws {
        let backend = MockAppearanceBackend()
        let service = AppearanceService(backend: backend, transitionBackend: nil)
        defer { service.shutdown() }

        let state = try await service.read()
        #expect(state.availability == .unsupported("原生外观接口不可用。"))
        await #expect(throws: SwitchFailure.unsupported("原生外观接口不可用。")) {
            try await service.setEnabled(true)
        }
        #expect(backend.events == [.read])
    }

    @Test func nativeFailureDoesNotBlockTheCoordinatorOrNextRequest() async {
        let backend = MockAppearanceBackend()
        let driver = TransitionDriverSpy()
        let native = NativeAppearanceTransitionBackend(driver: driver, timeout: .milliseconds(10))
        let service = AppearanceService(backend: backend, transitionBackend: native)
        let coordinator = SwitchCoordinator(services: [service])
        defer { coordinator.shutdown() }

        coordinator.setEnabled(true, for: .appearance)
        coordinator.setEnabled(false, for: .appearance)
        await coordinator.waitUntilIdle()
        #expect(!coordinator.isBusy)
        #expect(coordinator.state(.appearance).pendingTarget == nil)
        #expect(!coordinator.state(.appearance).displayedEnabled)
        #expect(coordinator.state(.appearance).isUnsupported)
        #expect(driver.callbacks.count == 1)
    }

    @Test func shutdownDuringTransitionDoesNotStartAnotherOperation() async {
        let backend = MockAppearanceBackend()
        let driver = TransitionDriverSpy()
        let service = AppearanceService(backend: backend, transitionBackend: NativeAppearanceTransitionBackend(driver: driver))
        let task = Task { try await service.setEnabled(true) }
        while driver.callbacks.isEmpty { await Task.yield() }
        service.shutdown()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(backend.events.isEmpty)
    }

    @Test func readsNeverChangeSystemAppearance() async throws {
        let backend = MockAppearanceBackend()
        let service = AppearanceService(backend: backend, transitionBackend: NativeAppearanceTransitionBackend(driver: TransitionDriverSpy()))
        defer { service.shutdown() }

        #expect(try await !service.read().isEnabled)
        backend.darkMode = true
        #expect(try await service.read().isEnabled)
        #expect(backend.events == [.read, .read])
    }
}

@MainActor
private final class MockAppearanceBackend: AppearanceBackend {
    enum Event: Equatable { case read }
    var events: [Event] = []
    var darkMode = false
    func readDarkMode() -> Bool {
        events.append(.read)
        return darkMode
    }
}
