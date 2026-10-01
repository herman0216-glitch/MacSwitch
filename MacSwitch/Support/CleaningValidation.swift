#if DEBUG
import AppKit

/// Developer-only, explicitly launched timed prototype. It does not add a
/// preference, admit a build to the support list, or change system settings.
@MainActor
final class CleaningValidation {
    private static var controller: CleaningValidation?
    private let resultURL: URL
    private let input = QuartzCleaningInputBackend()
    private let service: CleaningService
    private let window: NSWindow
    private let status = NSTextField(wrappingLabelWithString: "")
    private let startButton = NSButton(title: "开始 45 秒验证", target: nil, action: nil)
    private var watchdog: Process?
    private var watchdogPipe: Pipe?
    private var deadline: Task<Void, Never>?
    private var active = false
    private var requestedReason: String?
    private var before: [String: Any] = [:]
    private var spaceChanges = 0
    private var observer: NSObjectProtocol?
    private var sequence = 0

    static func show(resultURL: URL) {
        controller = CleaningValidation(resultURL: resultURL)
        controller?.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(resultURL: URL) {
        self.resultURL = resultURL
        service = CleaningService(backend: AppKitCleaningBackend(input: input, prototype: true))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 310),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "MacSwitch 清洁模式限时验证"
        window.isReleasedWhenClosed = false
        window.center()
        let instructions = NSTextField(wrappingLabelWithString:
            "点击开始后有 5 秒准备时间，可切回原来的应用。\n黑屏期间请真实操作：切桌面、调度中心、显示桌面、滚动、缩放、边缘及触发角。按钮外点击和拖入／拖出不应退出。\n45 秒自动退出；独立进程在 55 秒强制释放兜底。")
        status.stringValue = "此为待验收原型，正式清洁开关保持关闭。"
        startButton.target = self
        startButton.action = #selector(startClicked)
        let stack = NSStackView(views: [instructions, startButton, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        if let view = window.contentView {
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
                stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
                stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28)
            ])
        }
        service.onSessionChange = { active in AppModel.shared.hotKeys.isSuspended = active }
        service.onChange = { [weak self] in
            Task { @MainActor in
                guard let self, self.active, !self.service.isEnabled else { return }
                let state = try? await self.service.read()
                self.finish(reason: self.requestedReason ?? state?.detail ?? "按钮退出")
            }
        }
    }

    @objc private func startClicked() {
        guard !active else { return }
        active = true
        startButton.isEnabled = false
        requestedReason = nil
        sequence += 1
        Task { @MainActor [self] in
            for second in (1...5).reversed() {
                status.stringValue = "\(second) 秒后开启，可切回待验证的桌面及应用…"
                try? await Task.sleep(for: .seconds(1))
            }
            before = snapshot()
            spaceChanges = 0
            observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.spaceChanges += 1 }
                }
            do {
                try armWatchdog()
                writeResult(reason: "starting", after: [:])
                _ = try await service.setEnabled(true)
                status.stringValue = "验证中：45 秒后自动退出"
                writeResult(reason: "running", after: snapshot())
                deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(45)) } catch { return }
                    guard let self, self.active else { return }
                    self.requestedReason = "45 秒自动退出"
                    _ = try? await self.service.setEnabled(false)
                }
            } catch { finish(reason: "启动失败：\(error.localizedDescription)") }
        }
    }

    private func finish(reason: String) {
        guard active else { return }
        active = false
        deadline?.cancel()
        deadline = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        // Capture before activating the validation panel; foreground recovery
        // happens asynchronously and must still be checked by the human tester.
        writeResult(reason: reason, after: snapshot())
        watchdogPipe?.fileHandleForWriting.write(Data("cancel\n".utf8))
        try? watchdogPipe?.fileHandleForWriting.close()
        watchdogPipe = nil
        watchdog = nil
        startButton.isEnabled = true
        status.stringValue = "\(reason)\n事件统计已保存。手势及后台桌面效果仍需人工确认，可再次开始。"
    }

    private func armWatchdog() throws {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // This child is independent of the app's run loop. Re-check actual
        // parenthood before EACH signal so an exited/reused PID is never killed.
        process.arguments = ["-c", #"""
        if IFS= read -r -t 55 command; then exit 0; fi
        parent_now=$(/bin/ps -p "$$" -o ppid=)
        if [[ "${parent_now// /}" != "$1" ]]; then exit 0; fi
        /bin/kill -TERM "$1"
        /bin/sleep 2
        parent_now=$(/bin/ps -p "$$" -o ppid=)
        if [[ "${parent_now// /}" == "$1" ]]; then /bin/kill -KILL "$1"; fi
        """#, "cleaning-prototype-watchdog", String(getpid())]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] child in
            let childPID = child.processIdentifier
            Task { @MainActor in
                guard let self, self.active, self.watchdog?.processIdentifier == childPID else { return }
                self.requestedReason = "独立自动停止进程意外结束，验证已取消"
                _ = try? await self.service.setEnabled(false)
            }
        }
        try process.run()
        guard process.isRunning else { throw SwitchFailure.failed("独立自动停止进程未启动。") }
        watchdog = process
        watchdogPipe = pipe
    }

    private func snapshot() -> [String: Any] {
        ["frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1,
         "frontmostBundle": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown",
         "presentationOptions": NSApp.presentationOptions.rawValue,
         "screens": NSScreen.screens.map { ["name": $0.localizedName,
              "frame": NSStringFromRect($0.frame)] },
         "inputHealthy": input.isHealthy]
    }

    private func writeResult(reason: String, after: [String: Any]) {
        let payload: [String: Any] = ["build": CleaningCompatibility.systemBuild,
            "pid": getpid(), "sequence": sequence, "time": ISO8601DateFormatter().string(from: Date()),
            "reason": reason, "before": before, "after": after, "spaceChangeNotifications": spaceChanges,
            "eventCounts": Dictionary(uniqueKeysWithValues: input.eventCounts.map { (String($0.key), $0.value) }),
            "physicalGestureAcceptance": "NOT RUN / requires explicit human observations"]
        do {
            try FileManager.default.createDirectory(at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: resultURL, options: .atomic)
            let archive = resultURL.deletingPathExtension().appendingPathExtension("run-\(sequence)-\(reason == "running" ? "active" : "result").json")
            try data.write(to: archive, options: .atomic)
        } catch { status.stringValue = "无法保存验证记录：\(error.localizedDescription)" }
    }
}
#endif
