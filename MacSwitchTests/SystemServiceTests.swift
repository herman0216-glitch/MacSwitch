import Foundation
import IOKit.pwr_mgt
import Testing
@testable import MacSwitch

@MainActor
struct SystemServiceTests {
    @Test func desktopEnableDisableAndRepeatedOperation() async throws {
        let backend = FakeDesktopBackend()
        let service = DesktopService(backend: backend, files: DesktopFileHider(backend: FakeDesktopFileBackend()), verifiedBuilds: ["26A428"])

        #expect(try await service.setEnabled(true).isEnabled)
        #expect(backend.state == .target(hidden: true))
        #expect(backend.writes.count == 2)
        _ = try await service.setEnabled(true)
        #expect(backend.writes.count == 2)
        #expect(try await service.setEnabled(false).isEnabled == false)
        #expect(backend.state == .target(hidden: false))
        #expect(backend.writes.count == 4)
    }

    @Test func desktopMissingPreferencesArePreservedWhenPartialWriteFails() async {
        let backend = FakeDesktopBackend()
        backend.failWrites = [2]
        let service = DesktopService(backend: backend, files: DesktopFileHider(backend: FakeDesktopFileBackend()), verifiedBuilds: ["26A428"])

        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
        #expect(backend.state == DesktopPreferenceState(standardHideDesktopIcons: nil, hideDesktop: nil))
        #expect(backend.writes.map(\.value) == [true, nil, nil])
    }

    @Test func desktopPartialStateIsOffAndExplained() async throws {
        let backend = FakeDesktopBackend(state: .init(standardHideDesktopIcons: true, hideDesktop: false))
        let service = DesktopService(backend: backend, files: DesktopFileHider(backend: FakeDesktopFileBackend()), verifiedBuilds: ["26A428"])

        let state = try await service.read()
        #expect(!state.isEnabled)
        #expect(state.detail == "部分模式已隐藏")
        #expect(state.availability == .available)
    }

    @Test func desktopReadbackMismatchRollsBackOriginalValues() async {
        let original = DesktopPreferenceState(standardHideDesktopIcons: nil, hideDesktop: false)
        let backend = FakeDesktopBackend(state: original)
        backend.ignoreWrites = [2]
        let service = DesktopService(backend: backend, files: DesktopFileHider(backend: FakeDesktopFileBackend()), verifiedBuilds: ["26A428"])

        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
        #expect(backend.state == original)
    }

    @Test func desktopRollbackFailureReportsActualState() async {
        let backend = FakeDesktopBackend()
        backend.failWrites = [2, 3]
        let service = DesktopService(backend: backend, files: DesktopFileHider(backend: FakeDesktopFileBackend()), verifiedBuilds: ["26A428"])

        do {
            _ = try await service.setEnabled(true)
            Issue.record("Expected the desktop write to fail")
        } catch {
            #expect(error.localizedDescription.contains("恢复未完成"))
            #expect(error.localizedDescription.contains("普通桌面=隐藏"))
        }
        #expect(backend.state == .init(standardHideDesktopIcons: true, hideDesktop: nil))
    }

    @Test func desktopExternalChangesAreReadWithoutWriting() async throws {
        let backend = FakeDesktopBackend()
        let files = FakeDesktopFileBackend(items: ["a": true])
        let service = DesktopService(backend: backend, files: DesktopFileHider(backend: files), verifiedBuilds: ["26A428"])
        backend.state = .target(hidden: true)
        files.manifest = DesktopHiddenManifest(items: [DesktopHiddenItem(path: files.path("a"))])

        #expect(try await service.read().isEnabled)
        #expect(backend.writes.isEmpty)
    }

    @Test func legacyFinderPreferenceBlocksWritesWithoutRestartingProcesses() async throws {
        let backend = FakeDesktopBackend()
        backend.createDesktop = false
        let service = DesktopService(backend: backend, files: DesktopFileHider(backend: FakeDesktopFileBackend()), verifiedBuilds: ["26A428"])

        let state = try await service.read()
        #expect(state.availability == .unsupported("检测到旧版 CreateDesktop=false。请先按恢复说明恢复 Finder 桌面。"))
        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
        #expect(backend.writes.isEmpty)
    }

    @Test func admittedBuildsCanReadAndUnknownBuildCannotWrite() async throws {
        let backend = FakeDesktopBackend()
        let service = DesktopService(backend: backend, files: DesktopFileHider(backend: FakeDesktopFileBackend()))
        #expect(try await service.read().availability == .available)
        backend.systemBuild = "26A434"
        #expect(try await service.read().availability == .available)
        #expect(backend.writes.isEmpty)
        backend.systemBuild = "99Z999"

        let state = try await service.read()
        #expect(state.availability == .unsupported("当前系统版本（99Z999）尚未通过桌面交互验收，请在系统设置中管理桌面项目。"))
        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
        #expect(backend.writes.isEmpty)
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
    struct Write: Equatable { let key: DesktopPreferenceKey; let value: Bool? }
    var systemBuild = "26A428"
    var state: DesktopPreferenceState
    var createDesktop: Bool? = true
    var writes: [Write] = []
    var failWrites: Set<Int> = []
    var ignoreWrites: Set<Int> = []
    private var attempts = 0

    init(state: DesktopPreferenceState = .init(standardHideDesktopIcons: nil, hideDesktop: nil)) {
        self.state = state
    }

    func preferences() -> DesktopPreferenceState { state }
    func legacyCreateDesktop() -> Bool? { createDesktop }
    func write(_ value: Bool?, for key: DesktopPreferenceKey) throws {
        attempts += 1
        if failWrites.contains(attempts) { throw SwitchFailure.failed("模拟写入失败") }
        writes.append(Write(key: key, value: value))
        guard !ignoreWrites.contains(attempts) else { return }
        switch key {
        case .standardHideDesktopIcons: state.standardHideDesktopIcons = value
        case .hideDesktop: state.hideDesktop = value
        }
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
