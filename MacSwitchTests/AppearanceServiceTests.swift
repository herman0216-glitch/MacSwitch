import Testing
@testable import MacSwitch

@MainActor
struct AppearanceServiceTests {
    @Test func firstLaunchPrecedesPermissionAndWrite() async throws {
        let backend = MockAppearanceBackend()
        let service = AppearanceService(backend: backend)
        defer { service.shutdown() }

        let result = try await service.setEnabled(true)

        #expect(backend.events == [.ensureRunning, .permission, .write(true), .read])
        #expect(result.isEnabled)
        #expect(result.availability == .available)
    }

    @Test func deniedPermissionPreventsWrite() async throws {
        let backend = MockAppearanceBackend()
        backend.permissionError = .unauthorized("模拟拒绝自动化授权")
        let service = AppearanceService(backend: backend)
        defer { service.shutdown() }

        await #expect(throws: SwitchFailure.unauthorized("模拟拒绝自动化授权")) {
            try await service.setEnabled(true)
        }

        #expect(backend.events == [.ensureRunning, .permission])
        #expect(!backend.darkMode)
    }

    @Test func allowedOperationReturnsTheSystemReadback() async throws {
        let backend = MockAppearanceBackend()
        backend.darkMode = true
        backend.isRunning = true
        let service = AppearanceService(backend: backend)
        defer { service.shutdown() }

        let result = try await service.setEnabled(false)

        #expect(!result.isEnabled)
        #expect(result.detail == "跟随系统当前外观")
        #expect(backend.events == [.ensureRunning, .permission, .write(false), .read])
    }

    @Test func revokedPermissionIsRecheckedBeforeTheNextWrite() async throws {
        let backend = MockAppearanceBackend()
        let service = AppearanceService(backend: backend)
        defer { service.shutdown() }
        _ = try await service.setEnabled(true)
        backend.events.removeAll()
        backend.permissionError = .unauthorized("模拟授权已撤销")

        await #expect(throws: SwitchFailure.unauthorized("模拟授权已撤销")) {
            try await service.setEnabled(false)
        }

        #expect(backend.events == [.ensureRunning, .permission])
        #expect(try await service.read().isEnabled)
    }

    @Test(arguments: [false, true])
    func scriptFailureLeavesActualSystemStateReadable(partiallyApplied: Bool) async throws {
        let backend = MockAppearanceBackend()
        backend.scriptError = .failed("模拟脚本失败")
        backend.applyBeforeScriptError = partiallyApplied
        let service = AppearanceService(backend: backend)
        defer { service.shutdown() }

        await #expect(throws: SwitchFailure.failed("模拟脚本失败")) {
            try await service.setEnabled(true)
        }
        let actual = try await service.read()

        #expect(actual.isEnabled == partiallyApplied)
        #expect(backend.events == [.ensureRunning, .permission, .write(true), .read])
    }

    @Test func readsNeverLaunchOrRequestPermission() async throws {
        let backend = MockAppearanceBackend()
        backend.permissionError = .unauthorized("读取不应触发此权限错误")
        let service = AppearanceService(backend: backend)
        defer { service.shutdown() }

        #expect(try await service.read().isEnabled == false)
        backend.darkMode = true
        #expect(try await service.read().isEnabled)

        #expect(service.id == .appearance)
        #expect(backend.events == [.read, .read])
        #expect(!backend.isRunning)
    }

    @Test func launchFailureStopsBeforePermissionAndWrite() async throws {
        let backend = MockAppearanceBackend()
        backend.launchError = .failed("模拟启动失败")
        let service = AppearanceService(backend: backend)
        defer { service.shutdown() }

        await #expect(throws: SwitchFailure.failed("模拟启动失败")) {
            try await service.setEnabled(true)
        }

        #expect(backend.events == [.ensureRunning])
        #expect(!backend.darkMode)
    }
}

@MainActor
private final class MockAppearanceBackend: AppearanceBackend {
    enum Event: Equatable {
        case ensureRunning, permission, write(Bool), read
    }

    var events: [Event] = []
    var darkMode = false
    var isRunning = false
    var launchError: SwitchFailure?
    var permissionError: SwitchFailure?
    var scriptError: SwitchFailure?
    var applyBeforeScriptError = false

    func readDarkMode() -> Bool {
        events.append(.read)
        return darkMode
    }

    func ensureSystemEventsRunning() async throws {
        events.append(.ensureRunning)
        if let launchError { throw launchError }
        isRunning = true
    }

    func requestAutomationPermission() async throws {
        events.append(.permission)
        guard isRunning else { throw SwitchFailure.failed("System Events 未运行（-600）") }
        if let permissionError { throw permissionError }
    }

    func setDarkMode(_ enabled: Bool) async throws {
        events.append(.write(enabled))
        if let scriptError {
            if applyBeforeScriptError { darkMode = enabled }
            throw scriptError
        }
        darkMode = enabled
    }
}
