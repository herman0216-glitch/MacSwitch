import AppKit

@main
struct DesktopProbe {
    @MainActor static func main() async throws {
        let backend = WindowManagerDesktopBackend()
        let state = backend.preferences()
        print("build=\(backend.systemBuild)")
        print("standardHideDesktopIcons=\(String(describing: state.standardHideDesktopIcons))")
        print("hideDesktop=\(String(describing: state.hideDesktop))")
        print("legacyCreateDesktop=\(String(describing: backend.legacyCreateDesktop()))")

        if let action = CommandLine.arguments.dropFirst().first, action == "hide" || action == "show" {
            guard CommandLine.arguments.contains("--desktop-probe"),
                  backend.systemBuild == DesktopCompatibility.prototypeBuild else {
                throw SwitchFailure.unsupported("写入仅允许在候选 build 上配合 --desktop-probe 执行。")
            }
            let service = DesktopService(backend: backend, verifiedBuilds: [DesktopCompatibility.prototypeBuild])
            print(try await service.setEnabled(action == "hide"))
        }
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where window[kCGWindowOwnerName as String] as? String == "Finder" {
            print("Finder window: layer=\(window[kCGWindowLayer as String] ?? "?") onscreen=\(window[kCGWindowIsOnscreen as String] ?? "?") bounds=\(window[kCGWindowBounds as String] ?? "?")")
        }
    }
}
