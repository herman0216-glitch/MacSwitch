import Testing
@testable import MacSwitch

@MainActor
struct CoordinatorTests {
    @Test func queuedTogglesUseActualStateAndNeverOverlap() async {
        let service = MockSwitchService()
        let store = SwitchCoordinator(services: [service])
        store.toggle(.appearance)
        store.toggle(.appearance)
        store.toggle(.appearance)
        await store.waitUntilIdle()
        #expect(service.writes == [true, false, true])
        #expect(service.maximumConcurrentWrites == 1)
        #expect(store.state(.appearance).snapshot.isEnabled)
        #expect(store.state(.appearance).phase == .succeeded)
        store.shutdown()
    }

    @Test func failedWriteReadsBackSystemAndReportsError() async {
        let service = MockSwitchService()
        service.error = .failed("测试失败")
        let store = SwitchCoordinator(services: [service])
        store.setEnabled(true, for: .appearance)
        await store.waitUntilIdle()
        #expect(!store.state(.appearance).snapshot.isEnabled)
        #expect(store.state(.appearance).phase == .failed("测试失败"))
        service.error = nil
        store.setEnabled(true, for: .appearance)
        await store.waitUntilIdle()
        #expect(store.state(.appearance).snapshot.isEnabled)
        store.shutdown()
    }

    @Test func permissionFailureOnlyAffectsItsFeature() async {
        let appearance = MockSwitchService()
        let desktop = MockSwitchService(id: .desktop)
        appearance.error = .unauthorized("拒绝")
        let store = SwitchCoordinator(services: [appearance, desktop])
        store.toggle(.appearance)
        store.toggle(.desktop)
        await store.waitUntilIdle()
        #expect(store.state(.appearance).phase == .unauthorized("拒绝"))
        #expect(store.state(.desktop).snapshot.isEnabled)
        store.shutdown()
    }

    @Test func externalChangesRefreshWithoutWriting() async {
        let service = MockSwitchService()
        let store = SwitchCoordinator(services: [service])
        store.refreshAll()
        await store.waitUntilIdle()
        service.snapshot.isEnabled = true
        service.onChange?()
        await store.waitUntilIdle()
        #expect(store.state(.appearance).snapshot.isEnabled)
        #expect(service.writes.isEmpty)
        store.shutdown()
    }

    @Test func unsupportedDeviceCanRecoverOnRefresh() async {
        let service = MockSwitchService()
        service.snapshot.availability = .unsupported("无设备")
        let store = SwitchCoordinator(services: [service])
        store.refreshAll()
        await store.waitUntilIdle()
        #expect(store.state(.appearance).isUnsupported)
        service.snapshot.availability = .available
        store.refreshAll()
        await store.waitUntilIdle()
        #expect(!store.state(.appearance).isUnsupported)
        #expect(store.state(.appearance).phase == .idle)
        store.shutdown()
    }

    @Test func retryPreservesOriginalTargetAfterPartialWrite() async {
        let service = MockSwitchService()
        service.error = .failed("写后校验失败")
        service.partiallyApply = true
        let store = SwitchCoordinator(services: [service])
        store.toggle(.appearance)
        await store.waitUntilIdle()
        #expect(store.state(.appearance).snapshot.isEnabled)
        service.error = nil
        store.retry(.appearance)
        await store.waitUntilIdle()
        #expect(service.writes == [true])
        #expect(store.state(.appearance).snapshot.isEnabled)
        store.shutdown()
    }

    @Test func retryInitialReadDoesNotWrite() async {
        let service = MockSwitchService()
        service.failRead = true
        let store = SwitchCoordinator(services: [service])
        store.refreshAll()
        await store.waitUntilIdle()
        service.failRead = false
        store.retry(.appearance)
        await store.waitUntilIdle()
        #expect(service.writes.isEmpty)
        #expect(store.state(.appearance).hasRead)
        store.shutdown()
    }

    @Test func durationChangeDoesNotRestartAnExpiredSession() async {
        let service = MockSwitchService(id: .keepAwake)
        service.snapshot.isEnabled = true
        let store = SwitchCoordinator(services: [service])
        store.refreshAll()
        await store.waitUntilIdle()
        service.snapshot.isEnabled = false
        store.restartIfEnabled(.keepAwake)
        await store.waitUntilIdle()
        #expect(service.writes.isEmpty)
        #expect(!store.state(.keepAwake).snapshot.isEnabled)
        store.shutdown()
    }

    @Test func terminationRejectsNewCommandsAndReleasesServices() async {
        let service = MockSwitchService()
        let store = SwitchCoordinator(services: [service])
        store.beginStopping()
        store.toggle(.appearance)
        store.refreshAll()
        await store.waitUntilIdle()
        #expect(service.writes.isEmpty)
        store.shutdown()
    }
}

@MainActor
private final class MockSwitchService: SwitchService {
    let id: FeatureID
    var onChange: (@MainActor () -> Void)?
    var snapshot = SwitchSnapshot(isEnabled: false)
    var writes: [Bool] = []
    var error: SwitchFailure?
    var failRead = false
    var partiallyApply = false
    var concurrentWrites = 0
    var maximumConcurrentWrites = 0
    init(id: FeatureID = .appearance) { self.id = id }
    func read() async throws -> SwitchSnapshot {
        if failRead { throw SwitchFailure.failed("读取失败") }
        return snapshot
    }
    func setEnabled(_ enabled: Bool) async throws -> SwitchSnapshot {
        concurrentWrites += 1
        maximumConcurrentWrites = max(maximumConcurrentWrites, concurrentWrites)
        defer { concurrentWrites -= 1 }
        await Task.yield()
        if let error {
            if partiallyApply { snapshot.isEnabled = enabled }
            throw error
        }
        writes.append(enabled)
        snapshot.isEnabled = enabled
        return snapshot
    }
}
