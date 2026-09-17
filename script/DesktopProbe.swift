import AppKit

@main
struct DesktopProbe {
    @MainActor static func main() async throws {
        let service = DesktopService()
        let original = FinderDesktopBackend().preference()
        print("preference=\(String(describing: original))")
        if let action = CommandLine.arguments.dropFirst().first {
            if action == "hide" || action == "show" {
                print(try await service.setEnabled(action == "hide"))
            } else if action == "restore-absent" {
                let backend = FinderDesktopBackend()
                try backend.write(nil)
                try await backend.restartFinder()
                print(try await service.read())
            }
        }
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        for window in windows where window[kCGWindowOwnerName as String] as? String == "Finder" {
            print("Finder window: layer=\(window[kCGWindowLayer as String] ?? "?") onscreen=\(window[kCGWindowIsOnscreen as String] ?? "?") bounds=\(window[kCGWindowBounds as String] ?? "?")")
        }
        service.shutdown()
    }
}
