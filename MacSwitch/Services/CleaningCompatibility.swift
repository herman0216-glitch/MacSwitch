import AppKit
import Darwin

/// Private WindowServer event numbers, never NSEvent.EventType raw values.
/// Provenance: joshuarli/iss, commit 493b008f2ea8e9215877c39700e8ea3add800e97.
/// That source only demonstrates horizontal swipes; our broader suppression
/// must pass the physical acceptance matrix on each explicitly admitted build.
enum CleaningGestureCompatibility {
    static let gesture: UInt32 = 29
    static let dockControl: UInt32 = 30
    static let realTypeField = CGEventField(rawValue: 55)!
    static let requiredMask: CGEventMask = (1 << gesture) | (1 << dockControl)

    static func isPrivateGesture(callbackType: UInt32, realType: Int64) -> Bool {
        callbackType == gesture || callbackType == dockControl || realType == Int64(gesture) || realType == Int64(dockControl)
    }
}

enum CleaningCompatibility {
    // Admitted for continued on-device acceptance. 26A434 was enabled at the
    // user's request; the physical gesture matrix still needs verification.
    static let verifiedBuilds: Set<String> = ["26A428", "26A434"]
    static let prototypeBuild = "26A428"

    static var systemBuild: String {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 1 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func unavailability(build: String, hasCornerProtection: Bool, prototype: Bool = false,
                               verifiedBuilds: Set<String> = CleaningCompatibility.verifiedBuilds) -> String? {
        guard hasCornerProtection else { return "增强清洁模式需要 macOS 27 的触发角保护，当前系统不受支持。" }
        if verifiedBuilds.contains(build) { return nil }
        #if DEBUG
        if prototype && build == prototypeBuild { return nil }
        #endif
        return "当前系统版本（\(build)）尚未通过真实触控板验收，清洁模式保持关闭。"
    }

    static var presentationOptions: NSApplication.PresentationOptions? {
        if #available(macOS 27.0, *) {
            return [.hideDock, .hideMenuBar, .disableScreenCornerInteractions]
        }
        return nil
    }
}
