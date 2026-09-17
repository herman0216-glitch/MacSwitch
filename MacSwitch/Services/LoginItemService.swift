import ServiceManagement
import Observation

@MainActor @Observable
final class LoginItemService {
    private(set) var enabled = false
    private(set) var busy = false
    private(set) var message: String?

    init() { refresh() }
    func refresh() {
        switch SMAppService.mainApp.status {
        case .enabled: enabled = true; message = nil
        case .requiresApproval: enabled = false; message = "请在系统设置 → 通用 → 登录项与扩展中允许 MacSwitch。"
        case .notRegistered: enabled = false; message = nil
        case .notFound: enabled = false; message = nil
        @unknown default: enabled = false; message = "无法读取登录启动状态。"
        }
    }
    func setEnabled(_ value: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            if value { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
            refresh()
        } catch {
            refresh()
            message = "登录启动设置失败：\(error.localizedDescription)"
        }
    }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}
