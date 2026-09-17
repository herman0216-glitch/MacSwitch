import Foundation
import IOKit.pwr_mgt
import Testing
@testable import MacSwitch

@MainActor
struct SystemServiceTests {
    @Test func desktopFailureRestoresAbsentPreference() async throws {
        let backend = FakeDesktopBackend()
        backend.failRestarts = 1
        let service = DesktopService(backend: backend)
        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
        #expect(backend.value == nil)
        #expect(backend.writtenValues.count == 2)
        #expect(backend.restarts == 2)
        service.shutdown()
    }

    @Test func desktopRoundTripAndNoOp() async throws {
        let backend = FakeDesktopBackend()
        let service = DesktopService(backend: backend)
        let hidden = try await service.setEnabled(true)
        #expect(hidden.isEnabled)
        _ = try await service.setEnabled(true)
        #expect(backend.restarts == 1)
        let visible = try await service.setEnabled(false)
        #expect(!visible.isEnabled)
        #expect(backend.value == true)
        service.shutdown()
    }

    @Test func awakeCountdownExpirationAndRestartDefaultOff() async throws {
        let backend = FakePowerBackend()
        let clock = FakeClock()
        let service = KeepAwakeService(backend: backend, now: { clock.now })
        #expect(try await service.read().isEnabled == false)
        _ = try await service.setEnabled(true)
        #expect(backend.timeout == 1800)
        clock.now = 65
        #expect(try await service.read().detail == "剩余 28:55")
        clock.now = 1800
        #expect(try await service.read().isEnabled == false)
        #expect(backend.active.isEmpty)
        service.shutdown()
        let restarted = KeepAwakeService(backend: backend)
        #expect(try await restarted.read().isEnabled == false)
        restarted.shutdown()
    }

    @Test func awakeManualStopUnlimitedAndShutdown() async throws {
        let backend = FakePowerBackend()
        let service = KeepAwakeService(backend: backend)
        service.duration = .untilDisabled
        _ = try await service.setEnabled(true)
        #expect(backend.timeout == nil)
        #expect(backend.active.count == 2)
        _ = try await service.setEnabled(false)
        #expect(backend.active.isEmpty)
        _ = try await service.setEnabled(true)
        service.shutdown()
        #expect(backend.active.isEmpty)
    }

    @Test func awakeFailedReleaseRetainsActualOnStateAndCanRetry() async throws {
        let backend = FakePowerBackend()
        let service = KeepAwakeService(backend: backend)
        _ = try await service.setEnabled(true)
        backend.failRelease = true
        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(false) }
        #expect(try await service.read().isEnabled)
        backend.failRelease = false
        _ = try await service.setEnabled(false)
        #expect(backend.active.isEmpty)
        service.shutdown()
    }

    @Test func awakeQueryFailureDoesNotLoseOwnedAssertions() async throws {
        let backend = FakePowerBackend()
        let service = KeepAwakeService(backend: backend)
        _ = try await service.setEnabled(true)
        backend.failQuery = true
        await #expect(throws: SwitchFailure.self) { try await service.read() }
        backend.failQuery = false
        _ = try await service.setEnabled(false)
        #expect(backend.active.isEmpty)
        service.shutdown()
    }
}

@MainActor private final class FakeClock {
    var now: TimeInterval = 0
}

@MainActor private final class FakeDesktopBackend: DesktopBackend {
    var value: Bool?
    var writtenValues: [Bool?] = []
    var failRestarts = 0
    var restarts = 0
    func preference() -> Bool? { value }
    func write(_ value: Bool?) throws { self.value = value; writtenValues.append(value) }
    func restartFinder() async throws {
        restarts += 1
        if failRestarts > 0 { failRestarts -= 1; throw SwitchFailure.failed("刷新失败") }
    }
}

@MainActor private final class FakePowerBackend: PowerAssertionBackend {
    var active: Set<IOPMAssertionID> = []
    var timeout: TimeInterval?
    var failRelease = false
    var failQuery = false
    func create(timeout: TimeInterval?) throws -> [IOPMAssertionID] {
        self.timeout = timeout
        active = [1, 2]
        return [1, 2]
    }
    func isActive(_ id: IOPMAssertionID) throws -> Bool {
        if failQuery { throw SwitchFailure.failed("查询失败") }
        return active.contains(id)
    }
    func release(_ id: IOPMAssertionID) throws {
        if failRelease { throw SwitchFailure.failed("释放失败") }
        active.remove(id)
    }
}
