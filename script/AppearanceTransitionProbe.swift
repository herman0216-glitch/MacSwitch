// Independent experiment. Never linked into the app; no capture or permission prompts.
// Reference: https://gist.github.com/avaidyam/6d0e3605cf85b10f4d0f9d654518e984
import AppKit
import ObjectiveC

@MainActor
private final class CompletionTime {
    var value: TimeInterval?
}

@main
struct AppearanceTransitionProbe {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { print("FAILED: \(error)"); exit(1) }
        }
        app.run()
    }

    @MainActor static func run() async throws {
        let mode = CommandLine.arguments.dropFirst().first ?? "inspect"
        guard ["inspect", "native"].contains(mode) else {
            throw NSError(domain: "Usage: inspect | native", code: 1)
        }
        let workspace = NSWorkspace.shared
        print("os=\(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("screens=\(NSScreen.screens.map(\.localizedName)) reduceMotion=\(workspace.accessibilityDisplayShouldReduceMotion)")
        guard let cls = NSClassFromString("NSGlobalPreferenceTransition"),
              let factory = class_getClassMethod(cls, NSSelectorFromString("transition")),
              let post = class_getInstanceMethod(cls, NSSelectorFromString("postChangeNotification:completionHandler:")),
              let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let getSymbol = dlsym(library, "SLSGetAppearanceThemeLegacy"),
              let setSymbol = dlsym(library, "SLSSetAppearanceThemeNotifying") else {
            throw NSError(domain: "Required symbols missing", code: 2)
        }
        defer { dlclose(library) }
        for name in ["transition", "postChangeNotification:completionHandler:", "waitForTransitionWithCompletionHandler:"] {
            let selector = NSSelectorFromString(name)
            let method = class_getClassMethod(cls, selector) ?? class_getInstanceMethod(cls, selector)
            print("\(name)=\(method.map { String(cString: method_getTypeEncoding($0)!) } ?? "MISSING")")
        }
        // Exact ABI confirmed on this build only. Inspection on other builds is safe;
        // a benchmark refuses to call an unknown method encoding or OS build.
        guard mode != "inspect" else { return }
        guard ProcessInfo.processInfo.operatingSystemVersionString.contains("26A428"),
              String(cString: method_getTypeEncoding(factory)!) == "@16@0:8",
              String(cString: method_getTypeEncoding(post)!) == "v32@0:8Q16@?24" else {
            throw NSError(domain: "Unreviewed build or ABI", code: 3)
        }
        let get = unsafeBitCast(getSymbol, to: (@convention(c) () -> Bool).self)
        let set = unsafeBitCast(setSymbol, to: (@convention(c) (Bool, Bool) -> Void).self)
        typealias Factory = @convention(c) (AnyClass, Selector) -> Unmanaged<AnyObject>
        typealias Post = @convention(c) (AnyObject, Selector, UInt64, @escaping @convention(block) () -> Void) -> Void
        let create = unsafeBitCast(method_getImplementation(factory), to: Factory.self)
        let notify = unsafeBitCast(method_getImplementation(post), to: Post.self)
        let original = get()
        func automaticPreference() -> String {
            CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
            return String(describing: CFPreferencesCopyValue("AppleInterfaceStyleSwitchesAutomatically" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost))
        }
        let automatic = automaticPreference()
        print("originalDark=\(original) automatic=\(automatic)")
        let recovery: [String: Any] = ["dark": original, "automatic": automatic]
        try JSONSerialization.data(withJSONObject: recovery, options: .sortedKeys).write(to: URL(fileURLWithPath: "build/probes/appearance-original.json"), options: .atomic)
        // Also restores after a thrown error; abrupt process death is not recoverable.
        defer {
            if get() != original { set(original, true) }
            print("restored=\(get() == original) automaticUnchanged=\(automaticPreference() == automatic)")
        }
        print("Timing values measure API/readback, NOT visible animation onset/end.")
        for index in 0..<20 {
            let target = !get()
            let completion = CompletionTime()
            let start = ProcessInfo.processInfo.systemUptime
            var transition: AnyObject?
            set(target, false)
            transition = create(cls, NSSelectorFromString("transition")).takeUnretainedValue()
            notify(transition!, NSSelectorFromString("postChangeNotification:completionHandler:"), 0) {
                let timestamp = ProcessInfo.processInfo.systemUptime
                Task { @MainActor in
                    if completion.value == nil { completion.value = timestamp }
                }
            }
            let returned = ProcessInfo.processInfo.systemUptime - start
            var readback: TimeInterval?
            while ProcessInfo.processInfo.systemUptime - start < 3 {
                if readback == nil, get() == target { readback = ProcessInfo.processInfo.systemUptime - start }
                if readback != nil, completion.value != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            withExtendedLifetime(transition) {}
            let row: [String: Any] = ["mode": mode, "sample": index + 1, "dark": target,
                "return_ms": returned * 1000, "readback_ms": readback.map { $0 * 1000 } ?? -1,
                "callback_ms": completion.value.map { ($0 - start) * 1000 } ?? -1]
            print(String(data: try JSONSerialization.data(withJSONObject: row, options: .sortedKeys), encoding: .utf8)!)
            guard readback != nil else { throw NSError(domain: "Readback failed", code: 5) }
            // Spacing is measurement isolation, never production latency.
            try await Task.sleep(for: .milliseconds(750))
        }
    }
}
