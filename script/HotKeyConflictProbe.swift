import Carbon
import AppKit
import Foundation

/// Hold only the test combination Control-Option-Command-K in another process.
/// Start while MacSwitch is closed, then launch MacSwitch with that saved binding.
@main
struct HotKeyConflictProbe {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x4d535450, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey | cmdKey), identifier, GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        defer { UnregisterEventHotKey(reference) }
        print("Holding Control-Option-Command-K exclusively for 120 seconds; pid=\(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
        RunLoop.current.run(until: Date().addingTimeInterval(120))
        print("Released test hotkey")
    }
}
