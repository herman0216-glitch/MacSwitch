import AppKit
import CryptoKit
import Security
import Darwin

struct HelperReady: Codable {
    let pid: Int32
    let connection: Int32
    let window: UInt32
    let original: WindowState
    let build: String
}

struct GuardianReady: Codable {
    let pid: Int32
    let ownerPID: Int32
    let timeoutSeconds: Int
}

struct Operation: Codable {
    let name: String
    let connection: Int32
    let returnCode: Int32
    let observed: WindowState
}

struct RestoreResult: Codable {
    let reason: String
    let before: WindowState
    let after: WindowState
    let alphaReturnCode: Int32
    let orderReturnCode: Int32
    let originalRestored: Bool
}

@main @MainActor struct RuntimeProbe {
    static func argument(_ name: String) -> String? {
        guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[index + 1]
    }

    static var build: String {
        var length = 0
        guard sysctlbyname("kern.osversion", nil, &length, nil, 0) == 0, length > 1 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname("kern.osversion", &bytes, &length, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let directory = URL(fileURLWithPath: argument("--directory") ?? NSTemporaryDirectory()).standardizedFileURL
            do {
                let mode = argument("--mode") ?? "inventory"
                if mode != "inventory", !ProbePolicy.permitsMutation(build: build) {
                    throw ProbeError.failure("Unsupported build \(build); development target is \(ProbePolicy.developmentBuild)")
                }
                switch mode {
                case "inventory": try saveJSON(inventory(), to: directory.appendingPathComponent("inventory.json"))
                case "run": try await run(directory)
                case "owner": try await owner(directory)
                case "guardian": try await guardian(directory)
                case "crash-controller": try await crashController(directory)
                default: throw ProbeError.failure("Unknown mode \(mode)")
                }
                exit(0)
            } catch {
                try? saveJSON(["status": "ERROR", "error": error.localizedDescription, "build": build],
                              to: directory.appendingPathComponent("error-\(getpid()).json"))
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
        }
        app.run()
    }

    static func launch(_ mode: String, directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-g", Bundle.main.bundlePath, "--args", "--mode", mode, "--directory", directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ProbeError.failure("Could not launch \(mode)") }
    }

    static func waitFor(_ name: String, directory: URL, seconds: Double = 10) async throws -> URL {
        let file = directory.appendingPathComponent(name)
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < deadline {
            if FileManager.default.fileExists(atPath: file.path) { return file }
            if let errorFile = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .first(where: { $0.lastPathComponent.hasPrefix("error-") && $0.pathExtension == "json" }) {
                let failure = try loadJSON([String: String].self, from: errorFile)
                throw ProbeError.failure(failure["error"] ?? "Helper reported an error")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ProbeError.failure("Timeout waiting for \(name); helper has its own 12-second restore deadline")
    }

    static func signal(_ name: String, directory: URL) throws {
        try Data().write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    static func owner(_ directory: URL) async throws {
        let api = try SkyLight()
        let connection = api.mainConnection()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 380, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "MacSwitch · 独立窗口验证"
        window.contentView = NSTextField(labelWithString: "仅验证此测试窗口；超时自动恢复并关闭。")
        window.orderFront(nil)
        // AppKit / WindowServer registration can complete on the next run loop.
        try await Task.sleep(for: .milliseconds(250))
        let id = UInt32(window.windowNumber)
        let original = api.state(connection: connection, window: id)
        try saveJSON(original, to: directory.appendingPathComponent("initial-state.json"))
        try saveJSON(["pid": getpid(), "connection": connection, "window": Int32(bitPattern: id),
                      "appkitVisible": window.isVisible ? 1 : 0],
                     to: directory.appendingPathComponent("initial-identity.json"))
        guard original.readable, original.ordered == 1, original.alpha > 0 else {
            window.close()
            throw ProbeError.failure("Cannot establish a visible, readable test-window baseline")
        }
        let ready = HelperReady(pid: getpid(), connection: connection, window: id, original: original, build: build)
        try saveJSON(ready, to: directory.appendingPathComponent("owner-ready.json"))
        // This owner-side failsafe also applies if the independent guardian fails.
        // It does NOT claim to be a usable recovery mechanism for Finder.
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        var hidden = false
        while true {
            let timedOut = ProcessInfo.processInfo.systemUptime >= deadline
            let guardianRequested = FileManager.default.fileExists(atPath: directory.appendingPathComponent("restore.request").path)
            if timedOut || guardianRequested {
                let before = api.state(connection: connection, window: id)
                let alphaError = api.setAlpha(connection, id, original.alpha)
                let orderError = api.order(connection, id, original.ordered == 1 ? 1 : 0, 0)
                let after = api.state(connection: connection, window: id)
                let result = RestoreResult(reason: guardianRequested ? "independent-guardian-timeout" : "owner-failsafe-timeout",
                                           before: before, after: after, alphaReturnCode: alphaError,
                                           orderReturnCode: orderError,
                                           originalRestored: alphaError == 0 && orderError == 0 && after.matches(original))
                try saveJSON(result, to: directory.appendingPathComponent("restored.json"))
                window.close()
                guard result.originalRestored else { throw ProbeError.failure("Test window restoration failed") }
                return
            }
            if !hidden, FileManager.default.fileExists(atPath: directory.appendingPathComponent("self-hide.request").path) {
                let guardian = try loadJSON(GuardianReady.self, from: directory.appendingPathComponent("guardian-ready.json"))
                guard guardian.ownerPID == getpid(), guardian.timeoutSeconds == 6,
                      kill(guardian.pid, 0) == 0 else { throw ProbeError.failure("Independent guardian is not armed") }
                let alphaError = api.setAlpha(connection, id, 0)
                let alphaState = api.state(connection: connection, window: id)
                let orderError = api.order(connection, id, 0, 0)
                let operations = [Operation(name: "self-alpha-zero", connection: connection, returnCode: alphaError, observed: alphaState),
                                  Operation(name: "self-order-out", connection: connection, returnCode: orderError,
                                            observed: api.state(connection: connection, window: id))]
                try saveJSON(operations, to: directory.appendingPathComponent("self-hidden.json"))
                hidden = true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    static func guardian(_ directory: URL) async throws {
        let ready = try loadJSON(HelperReady.self, from: directory.appendingPathComponent("owner-ready.json"))
        guard ready.build == build, kill(ready.pid, 0) == 0 else { throw ProbeError.failure("Owner is not alive") }
        try saveJSON(GuardianReady(pid: getpid(), ownerPID: ready.pid, timeoutSeconds: 6),
                     to: directory.appendingPathComponent("guardian-ready.json"))
        try await Task.sleep(for: .seconds(6))
        try signal("restore.request", directory: directory)
    }

    static func crashController(_ directory: URL) async throws {
        try signal("self-hide.request", directory: directory)
        let operations = try loadJSON([Operation].self, from: await waitFor("self-hidden.json", directory: directory))
        guard operations.last?.observed.hidden == true else { throw ProbeError.failure("Crash test must first hide a test window") }
        try saveJSON(["pid": getpid(), "signal": SIGKILL], to: directory.appendingPathComponent("crash-issued.json"))
        kill(getpid(), SIGKILL)
        throw ProbeError.failure("SIGKILL unexpectedly returned")
    }

    static func prepare(_ name: String, root: URL) async throws -> (URL, HelperReady) {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try launch("owner", directory: directory)
        let ready = try loadJSON(HelperReady.self, from: await waitFor("owner-ready.json", directory: directory))
        try launch("guardian", directory: directory)
        _ = try await waitFor("guardian-ready.json", directory: directory)
        return (directory, ready)
    }

    static func run(_ root: URL) async throws {
        let baseline = environment()
        try saveJSON(inventory(), to: root.appendingPathComponent("inventory.json"))
        try saveJSON(baseline, to: root.appendingPathComponent("environment-before.json"))

        let (selfDirectory, _) = try await prepare("self-window", root: root)
        try signal("self-hide.request", directory: selfDirectory)
        let selfOperations = try loadJSON([Operation].self, from: await waitFor("self-hidden.json", directory: selfDirectory))
        let selfRestored = try loadJSON(RestoreResult.self, from: await waitFor("restored.json", directory: selfDirectory))
        guard selfOperations.allSatisfy({ $0.returnCode == 0 }), selfOperations.last?.observed.hidden == true,
              selfOperations.first?.observed.alpha == 0,
              selfRestored.originalRestored, selfRestored.reason == "independent-guardian-timeout" else {
            throw ProbeError.failure("Owned-window ABI / independent timeout recovery did not pass")
        }

        let (crashDirectory, _) = try await prepare("controller-crash", root: root)
        try launch("crash-controller", directory: crashDirectory)
        let crashed = try loadJSON([String: Int32].self, from: await waitFor("crash-issued.json", directory: crashDirectory))
        let crashRestore = try loadJSON(RestoreResult.self, from: await waitFor("restored.json", directory: crashDirectory))
        let crashedPID = crashed["pid"] ?? -1
        guard crashedPID > 0, kill(crashedPID, 0) != 0, errno == ESRCH,
              crashRestore.before.hidden, crashRestore.originalRestored,
              crashRestore.reason == "independent-guardian-timeout" else {
            throw ProbeError.failure("Controller-crash recovery did not pass")
        }

        let (foreignDirectory, target) = try await prepare("foreign-window", root: root)
        let api = try SkyLight()
        let caller = api.mainConnection()
        var operations: [Operation] = []
        // A connection ID is an identifier, not an authority token. Test both
        // the caller ID and the target ID, without requesting elevated access.
        for connection in [caller, target.connection] {
            var ownerConnection: Int32 = 0
            var pid: pid_t = 0
            guard api.getOwner(caller, target.window, &ownerConnection) == 0,
                  api.getPID(ownerConnection, &pid) == 0,
                  ProbePolicy.validHelper(targetPID: target.pid, observedPID: pid,
                                          targetConnection: target.connection, observedConnection: ownerConnection,
                                          controllerPID: getpid()), kill(target.pid, 0) == 0 else {
                throw ProbeError.failure("Foreign helper identity changed; no further mutations")
            }
            let alphaError = api.setAlpha(connection, target.window, 0)
            try await Task.sleep(for: .milliseconds(200))
            operations.append(Operation(name: "foreign-alpha-zero", connection: connection, returnCode: alphaError,
                                        observed: api.state(connection: caller, window: target.window)))
            let orderError = api.order(connection, target.window, 0, 0)
            try await Task.sleep(for: .milliseconds(200))
            operations.append(Operation(name: "foreign-order-out", connection: connection, returnCode: orderError,
                                        observed: api.state(connection: caller, window: target.window)))
        }
        try saveJSON(operations, to: foreignDirectory.appendingPathComponent("operations.json"))
        let foreignRestore = try loadJSON(RestoreResult.self, from: await waitFor("restored.json", directory: foreignDirectory))
        guard foreignRestore.originalRestored else { throw ProbeError.failure("Foreign test window did not restore") }
        let unchanged = operations.allSatisfy { $0.observed.matches(target.original) }
        let rejected = operations.allSatisfy { $0.returnCode != 0 }
        let final = environment()
        try saveJSON(final, to: root.appendingPathComponent("environment-after.json"))
        let preserved = baseline == final && !baseline.values.contains("UNREADABLE") && !final.values.contains("UNREADABLE")
        try saveJSON([
            "build": build,
            "developmentTarget": ProbePolicy.developmentBuild,
            "status": foreignControlStatus(original: target.original, observations: operations.map(\.observed),
                                           ownerBeforeRestore: foreignRestore.before, environmentPreserved: preserved),
            "ownedWindowABIAndRestore": "PASS",
            "independentTimeoutRecovery": "PASS (cooperative test-window owner only)",
            "controllerSIGKILLRecovery": "PASS (cooperative test-window owner only)",
            "foreignMutationsRejected": String(rejected),
            "foreignOrderCallsRejected": String(operations.filter { $0.name == "foreign-order-out" }.allSatisfy { $0.returnCode != 0 }),
            "zeroReturnWithoutStateChange": String(operations.contains { $0.returnCode == 0 && $0.observed.matches(target.original) }),
            "observationDelayMilliseconds": "200 per mutation, plus owner-side state at 6-second recovery deadline",
            "foreignWindowUnchanged": String(unchanged),
            "preferencesAndSystemPIDsUnchanged": String(preserved),
            "finderMutations": "0",
            "realDesktopRecovery": "NOT RUN",
            "physicalAcceptance": "NOT RUN",
            "phaseTwo": "NOT STARTED"
        ], to: root.appendingPathComponent("result.json"))
    }

    static func commandOutput(_ executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch { return nil }
    }

    static func environment() -> [String: String] {
        var result = ["build": build, "os": ProcessInfo.processInfo.operatingSystemVersionString]
        for domain in ["com.apple.WindowManager", "com.apple.finder", "com.apple.dock"] {
            // Separate defaults processes read fresh domains; only hashes are
            // recorded, so desktop filenames and other preference data stay private.
            if let data = commandOutput("/usr/bin/defaults", ["export", domain, "-"]),
               let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) {
                let stable = canonicalPropertyList(plist)
                let canonical = try? JSONSerialization.data(withJSONObject: stable, options: [.sortedKeys, .fragmentsAllowed])
                result[domain + ".sha256"] = canonical.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "UNREADABLE"
            } else { result[domain + ".sha256"] = "UNREADABLE" }
        }
        for (domain, keys) in ["com.apple.WindowManager": ["StandardHideDesktopIcons", "HideDesktop", "GloballyEnabled", "EnableStandardClickToShowDesktop", "StandardHideWidgets", "HideWidgets"],
                               "com.apple.finder": ["CreateDesktop"]] {
            for key in keys {
                let data = commandOutput("/usr/bin/defaults", ["read", domain, key])
                result[domain + "." + key] = data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "absent"
            }
        }
        for bundle in ["com.apple.finder", "com.apple.dock"] {
            result[bundle + ".pids"] = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
                .map { String($0.processIdentifier) }.sorted().joined(separator: ",")
        }
        result["sip"] = commandOutput("/usr/bin/csrutil", ["status"]).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? "UNREADABLE"
        return result
    }

    static func canonicalPropertyList(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] { return dictionary.mapValues { canonicalPropertyList($0) } }
        if let array = value as? [Any] { return array.map { canonicalPropertyList($0) } }
        if let data = value as? Data { return ["$data": data.base64EncodedString()] }
        if let date = value as? Date { return ["$date": date.timeIntervalSince1970] }
        return value
    }

    static func inventory() -> [String: String] {
        var result = ["build": build, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                      "finderMutationCount": "0", "developmentTarget": ProbePolicy.developmentBuild]
        result["accessibilityTrustedNoPrompt"] = String(AXIsProcessTrusted())
        result["screenCaptureAllowedNoPrompt"] = String(CGPreflightScreenCaptureAccess())
        do { _ = try SkyLight(); result["symbols"] = SkyLight.names.joined(separator: ",") }
        catch { result["symbols"] = error.localizedDescription }
        var requirement: SecRequirement?
        let requirementStatus = SecRequirementCreateWithString("identifier \"com.apple.finder\" and anchor apple" as CFString,
                                                               SecCSFlags(rawValue: 0), &requirement)
        let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
        var code: SecStaticCode?
        let expected = "/System/Library/CoreServices/Finder.app"
        let exactPath = finder?.bundleURL?.resolvingSymlinksInPath().path == expected
        let createStatus = SecStaticCodeCreateWithPath(URL(fileURLWithPath: expected) as CFURL, SecCSFlags(rawValue: 0), &code)
        let signatureStatus = code.map { SecStaticCodeCheckValidity($0, SecCSFlags(rawValue: 0), requirement) } ?? errSecParam
        let verified = finder != nil && exactPath && requirementStatus == errSecSuccess
            && createStatus == errSecSuccess && signatureStatus == errSecSuccess
        result["finderIdentityVerified"] = String(verified)
        result["finderSignatureStatus"] = String(signatureStatus)
        result["finderPID"] = finder.map { String($0.processIdentifier) } ?? "absent"
        let desktopLayer = CGWindowLevelForKey(.desktopIconWindow)
        result["desktopIconLayer"] = String(desktopLayer)
        var displays = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        let displayError = CGGetActiveDisplayList(UInt32(displays.count), &displays, &count)
        result["displayQueryError"] = String(displayError.rawValue)
        guard displayError == .success else { return result }
        let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] ?? []
        var candidates = [String]()
        var finderLayers = [String]()
        for window in windows where (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == finder?.processIdentifier {
            guard let id = window[kCGWindowNumber as String] as? NSNumber,
                  let layer = window[kCGWindowLayer as String] as? NSNumber,
                  let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { continue }
            finderLayers.append("\(id.uint32Value):\(layer.int32Value)")
            for display in displays.prefix(Int(count)) {
                let displayBounds = CGDisplayBounds(display)
                if ProbePolicy.isDesktopCandidate(verifiedFinder: verified, layer: layer.int32Value, desktopLayer: desktopLayer,
                                                  bounds: [bounds.minX, bounds.minY, bounds.width, bounds.height],
                                                  display: [displayBounds.minX, displayBounds.minY, displayBounds.width, displayBounds.height]) {
                    candidates.append("window=\(id.uint32Value),pid=\(finder!.processIdentifier),layer=\(layer.int32Value),display=\(display)")
                }
            }
        }
        result["activeDisplays"] = displays.prefix(Int(count)).map(String.init).joined(separator: ",")
        result["finderWindowLayers"] = finderLayers.joined(separator: ";")
        result["desktopCandidates"] = candidates.joined(separator: ";")
        result["candidateCount"] = String(candidates.count)
        result["targetIdentification"] = "READ ONLY; bundle identity + Apple signature + PID + exact layer + display bounds; not an ownership grant"
        return result
    }
}
