import Carbon
import Foundation

struct RecordedShortcut: Codable, Equatable, Hashable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    func validate() throws {
        let allowed = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        guard modifiers & ~allowed == 0,
              modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 else {
            throw ShortcutValidationError.modifierRequired
        }
        guard keyCode <= 126,
              ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 72, 73, 74].contains(keyCode) else {
            throw ShortcutValidationError.unsupportedKey
        }
        let command = modifiers & UInt32(cmdKey) != 0
        let control = modifiers & UInt32(controlKey) != 0
        let option = modifiers & UInt32(optionKey) != 0
        let shift = modifiers & UInt32(shiftKey) != 0
        let primary = modifiers & UInt32(cmdKey | controlKey | optionKey)
        // Keep app/window commands, input switching, screenshots and system navigation available.
        let appCommand = primary == UInt32(cmdKey)
            && [0, 1, 3, 4, 6, 7, 8, 9, 12, 13, 14, 31, 35, 43, 45, 46, 51].contains(keyCode)
        let appSwitch = command && keyCode == 48
        let spotlightOrInput = keyCode == 49 && (command || control)
        let lockScreen = command && control && keyCode == 12
        let dock = command && option && keyCode == 2
        let screenshot = command && shift && [20, 21, 23, 22].contains(keyCode)
        let systemNavigation = control && ([123, 124, 125, 126, 120, 99, 118, 96, 97, 98, 100].contains(keyCode))
        guard keyCode != 53, !appCommand, !appSwitch, !spotlightOrInput,
              !lockScreen, !dock, !screenshot, !systemNavigation else {
            throw ShortcutValidationError.reserved
        }
    }

    private static func keyName(for code: UInt32) -> String {
        let special: [UInt32: String] = [
            36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 65: ".",
            67: "*", 69: "+", 75: "/", 76: "⌤", 78: "−", 81: "=",
            82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5",
            88: "6", 89: "7", 91: "8", 92: "9", 96: "F5", 97: "F6",
            98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11",
            105: "F13", 106: "F16", 107: "F14", 109: "F10", 111: "F12",
            113: "F15", 114: "Help", 115: "↖", 116: "⇞", 117: "⌦",
            118: "F4", 119: "↘", 120: "F2", 121: "⇟", 122: "F1",
            123: "←", 124: "→", 125: "↓", 126: "↑", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        if let name = special[code] { return name }
        if let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
           let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
            if let bytes = CFDataGetBytePtr(data) {
                let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKeyState: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeyState, characters.count, &length, &characters)
                if status == noErr, length > 0 {
                    return String(utf16CodeUnits: characters, count: length).uppercased()
                }
            }
        }
        return "键 \(code)"
    }
}

enum ShortcutValidationError: Error, LocalizedError, Equatable {
    case modifierRequired, unsupportedKey, reserved

    var errorDescription: String? {
        switch self {
        case .modifierRequired: "请至少包含 ⌘、⌃ 或 ⌥ 中的一个修饰键。"
        case .unsupportedKey: "此按键不能用作快捷键。"
        case .reserved: "此组合键用于常用应用或系统操作，请选择其他组合。"
        }
    }
}
