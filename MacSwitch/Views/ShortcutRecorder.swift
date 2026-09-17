import AppKit
import Carbon
import SwiftUI

@MainActor
struct ShortcutRecorder: View {
    let shortcut: RecordedShortcut?
    let onRecord: (RecordedShortcut?) throws -> Void
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 6) {
                RecorderButton(shortcut: shortcut, onRecord: onRecord, onError: { errorMessage = $0 })
                    .frame(width: 170, height: 28)
                Button {
                    do {
                        try onRecord(nil)
                        errorMessage = nil
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .disabled(shortcut == nil)
                .help("清除快捷键")
                .accessibilityLabel("清除快捷键")
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260, alignment: .trailing)
            }
        }
    }
}

@MainActor
private struct RecorderButton: NSViewRepresentable {
    let shortcut: RecordedShortcut?
    let onRecord: (RecordedShortcut?) throws -> Void
    let onError: (String?) -> Void

    func makeNSView(context: Context) -> ShortcutCaptureButton {
        let button = ShortcutCaptureButton()
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: ShortcutCaptureButton, context: Context) {
        button.shortcut = shortcut
        button.onRecord = onRecord
        button.onError = onError
        button.refreshTitle()
    }

    static func dismantleNSView(_ button: ShortcutCaptureButton, coordinator: ()) {
        button.stopRecording()
    }
}

@MainActor
private final class ShortcutCaptureButton: NSButton {
    var shortcut: RecordedShortcut?
    var onRecord: ((RecordedShortcut?) throws -> Void)?
    var onError: ((String?) -> Void)?
    private var recordingID: UUID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(beginRecording)
        focusRingType = .default
        setAccessibilityLabel("录制全局快捷键")
        toolTip = "点击后按组合键；至少包含 ⌘、⌃ 或 ⌥。Esc 取消，Tab 离开。"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    @objc private func beginRecording() {
        guard recordingID == nil, window?.makeFirstResponder(self) == true else { return }
        onError?(nil)
        recordingID = HotKeyService.beginRecording { [weak self] shortcut in self?.record(shortcut) }
        refreshTitle()
    }

    func stopRecording() {
        if let recordingID { HotKeyService.endRecording(recordingID) }
        recordingID = nil
        refreshTitle()
    }

    func refreshTitle() {
        title = recordingID == nil ? (shortcut?.displayName ?? "录制快捷键…") : "请按组合键 · Esc 取消"
        setAccessibilityValue(title)
    }

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        }
        if let newWindow {
            NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus),
                                                   name: NSWindow.didResignKeyNotification, object: newWindow)
        } else {
            stopRecording()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    @objc private func windowLostFocus() { stopRecording() }

    override func keyDown(with event: NSEvent) {
        guard recordingID != nil else {
            if event.keyCode == 36 || event.keyCode == 49 { beginRecording() }
            else { super.keyDown(with: event) }
            return
        }
        consume(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recordingID != nil, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        consume(event)
        return true
    }

    private func consume(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 {
            stopRecording()
            onError?(nil)
            return
        }
        if event.keyCode == 48, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            stopRecording()
            if event.modifierFlags.contains(.shift) { window?.selectPreviousKeyView(self) }
            else { window?.selectNextKeyView(self) }
            return
        }
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.control) { modifiers |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { modifiers |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        record(RecordedShortcut(keyCode: UInt32(event.keyCode), modifiers: modifiers))
    }

    private func record(_ shortcut: RecordedShortcut) {
        guard recordingID != nil else { return }
        do {
            try shortcut.validate()
            try onRecord?(shortcut)
            self.shortcut = shortcut
            onError?(nil)
            stopRecording()
        } catch {
            onError?(error.localizedDescription)
        }
    }

    isolated deinit {
        if let recordingID { HotKeyService.endRecording(recordingID) }
        NotificationCenter.default.removeObserver(self)
    }
}
