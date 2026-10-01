import AppKit
import Darwin

enum DesktopPreferenceKey: CaseIterable, Sendable {
    case standardHideDesktopIcons
    case hideDesktop

    var rawValue: String {
        switch self {
        case .standardHideDesktopIcons: "StandardHideDesktopIcons"
        case .hideDesktop: "HideDesktop"
        }
    }
}

struct DesktopPreferenceState: Equatable, Sendable {
    var standardHideDesktopIcons: Bool?
    var hideDesktop: Bool?

    var isFullyHidden: Bool {
        standardHideDesktopIcons == true && hideDesktop == true
    }

    var isPartiallyHidden: Bool {
        !isFullyHidden && (standardHideDesktopIcons == true || hideDesktop == true)
    }

    func value(for key: DesktopPreferenceKey) -> Bool? {
        switch key {
        case .standardHideDesktopIcons: standardHideDesktopIcons
        case .hideDesktop: hideDesktop
        }
    }

    static func target(hidden: Bool) -> DesktopPreferenceState {
        DesktopPreferenceState(standardHideDesktopIcons: hidden, hideDesktop: hidden)
    }
}

enum DesktopCompatibility {
    // Explicit build admission. 26A434 was enabled at the user's request for
    // continued use/testing; admission is not full desktop interaction certification.
    static let verifiedBuilds: Set<String> = ["26A428", "26A434"]
    static let prototypeBuild = "26A428"

    static var runtimeBuilds: Set<String> {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--desktop-probe"), systemBuild == prototypeBuild {
            return verifiedBuilds.union([prototypeBuild])
        }
        #endif
        return verifiedBuilds
    }

    static var systemBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func unavailability(build: String, verifiedBuilds: Set<String> = verifiedBuilds) -> String? {
        guard verifiedBuilds.contains(build) else {
            return "当前系统版本（\(build)）尚未通过桌面交互验收，请在系统设置中管理桌面项目。"
        }
        return nil
    }
}

@MainActor
protocol DesktopBackend: AnyObject {
    var systemBuild: String { get }
    func preferences() -> DesktopPreferenceState
    func write(_ value: Bool?, for key: DesktopPreferenceKey) throws
    func legacyCreateDesktop() -> Bool?
}

@MainActor
final class WindowManagerDesktopBackend: DesktopBackend {
    private let domain = "com.apple.WindowManager" as CFString
    private let finderDomain = "com.apple.finder" as CFString
    private let legacyKey = "CreateDesktop" as CFString

    var systemBuild: String { DesktopCompatibility.systemBuild }

    func preferences() -> DesktopPreferenceState {
        CFPreferencesAppSynchronize(domain)
        return DesktopPreferenceState(
            standardHideDesktopIcons: boolValue(for: .standardHideDesktopIcons),
            hideDesktop: boolValue(for: .hideDesktop)
        )
    }

    func write(_ value: Bool?, for key: DesktopPreferenceKey) throws {
        CFPreferencesSetAppValue(key.rawValue as CFString, value.map { $0 as CFBoolean }, domain)
        guard CFPreferencesAppSynchronize(domain) else {
            throw SwitchFailure.failed("无法保存系统桌面项目偏好（\(key.rawValue)）。")
        }
    }

    func legacyCreateDesktop() -> Bool? {
        CFPreferencesAppSynchronize(finderDomain)
        return CFPreferencesCopyAppValue(legacyKey, finderDomain) as? Bool
    }

    private func boolValue(for key: DesktopPreferenceKey) -> Bool? {
        CFPreferencesCopyAppValue(key.rawValue as CFString, domain) as? Bool
    }
}

@MainActor
final class DesktopService: SwitchService {
    let id: FeatureID = .desktop
    var onChange: (@MainActor () -> Void)?
    private let backend: any DesktopBackend
    private let files: DesktopFileHider
    private let verifiedBuilds: Set<String>

    init(backend: any DesktopBackend = WindowManagerDesktopBackend(),
         files: DesktopFileHider = DesktopFileHider(),
         verifiedBuilds: Set<String> = DesktopCompatibility.runtimeBuilds) {
        self.backend = backend
        self.files = files
        self.verifiedBuilds = verifiedBuilds
    }

    func read() async throws -> SwitchSnapshot {
        let state = backend.preferences()
        let filesHidden = try files.isActive()
        let enabled = state.isFullyHidden && filesHidden
        if backend.legacyCreateDesktop() == false {
            return SwitchSnapshot(
                isEnabled: enabled,
                detail: "检测到旧版 Finder 隐藏设置，请先恢复桌面",
                availability: .unsupported("检测到旧版 CreateDesktop=false。请先按恢复说明恢复 Finder 桌面。")
            )
        }
        if let reason = DesktopCompatibility.unavailability(build: backend.systemBuild, verifiedBuilds: verifiedBuilds) {
            return SwitchSnapshot(isEnabled: enabled, detail: "此版本暂不启用系统隐藏后端", availability: .unsupported(reason))
        }
        // Keep hiding new items after relaunch; stop if the state was changed elsewhere.
        if enabled { files.startWatching() } else { files.stopWatching() }

        let detail: String
        if enabled {
            if files.showsAllFiles() {
                detail = "Finder 已开启显示隐藏文件，桌面项目仍会显示"
            } else if let error = files.lastWatchError {
                detail = "新项目隐藏失败：\(error)"
            } else {
                detail = "持续隐藏桌面项目，点击桌面与台前调度不受影响"
            }
        } else if state.isFullyHidden {
            detail = "仅系统临时隐藏，重新开启即可持续隐藏"
        } else if filesHidden || state.isPartiallyHidden {
            detail = "部分模式已隐藏"
        } else {
            detail = "持续隐藏桌面项目，点击桌面与台前调度不受影响"
        }
        return SwitchSnapshot(isEnabled: enabled, detail: detail)
    }

    func setEnabled(_ enabled: Bool) async throws -> SwitchSnapshot {
        if backend.legacyCreateDesktop() == false {
            throw SwitchFailure.unsupported("检测到旧版 CreateDesktop=false。请先按恢复说明恢复 Finder 桌面。")
        }
        if let reason = DesktopCompatibility.unavailability(build: backend.systemBuild, verifiedBuilds: verifiedBuilds) {
            throw SwitchFailure.unsupported(reason)
        }

        if enabled {
            let original = backend.preferences()
            try applyPreferences(.target(hidden: true))
            do {
                try files.hideAll()
            } catch {
                let cause = error
                let rollbackErrors = restore(original)
                if !rollbackErrors.isEmpty || backend.preferences() != original {
                    throw SwitchFailure.failed("\(cause.localizedDescription) 系统桌面偏好恢复未完成：\(describe(backend.preferences()))")
                }
                throw cause
            }
            files.startWatching()
        } else {
            files.stopWatching()
            do {
                try files.restoreAll()
            } catch {
                // Items still hidden: keep the switch on and keep watching.
                if try files.isActive(), backend.preferences().isFullyHidden { files.startWatching() }
                throw error
            }
            try applyPreferences(.target(hidden: false))
        }
        return try await read()
    }

    func shutdown() {
        files.stopWatching()
    }

    private func applyPreferences(_ target: DesktopPreferenceState) throws {
        let original = backend.preferences()
        if original == target { return }

        do {
            try apply(target)
            let observed = backend.preferences()
            guard observed == target else {
                throw SwitchFailure.failed("系统未确认桌面项目偏好。")
            }
        } catch {
            let cause = error.localizedDescription
            let rollbackErrors = restore(original)
            let actual = backend.preferences()
            guard rollbackErrors.isEmpty, actual == original else {
                let failures = rollbackErrors.isEmpty ? "读回状态与原始值不一致" : rollbackErrors.joined(separator: "；")
                throw SwitchFailure.failed("\(cause) 恢复未完成：\(failures)。实际状态：\(describe(actual))")
            }
            throw SwitchFailure.failed("\(cause) 已恢复本次操作前的桌面偏好。")
        }
    }

    private func apply(_ state: DesktopPreferenceState) throws {
        for key in DesktopPreferenceKey.allCases {
            try backend.write(state.value(for: key), for: key)
        }
    }

    private func restore(_ state: DesktopPreferenceState) -> [String] {
        var errors: [String] = []
        for key in DesktopPreferenceKey.allCases {
            do { try backend.write(state.value(for: key), for: key) }
            catch { errors.append("\(key.rawValue)：\(error.localizedDescription)") }
        }
        return errors
    }

    private func describe(_ state: DesktopPreferenceState) -> String {
        func value(_ value: Bool?) -> String {
            switch value {
            case true: "隐藏"
            case false: "显示"
            case nil: "未设置"
            }
        }
        return "普通桌面=\(value(state.standardHideDesktopIcons))，台前调度=\(value(state.hideDesktop))"
    }
}
