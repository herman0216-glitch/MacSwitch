import AppKit
import Foundation

/// Read-only inspection of the target process; never creates an event tap.
@main
enum CleaningResourceProbe {
    static func main() throws {
        guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
            throw NSError(domain: "CleaningResourceProbe", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Usage: CleaningResourceProbe PID"])
        }
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success else {
            throw NSError(domain: "CleaningResourceProbe", code: 2)
        }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        let result = taps.withUnsafeMutableBufferPointer { CGGetEventTapList(count, $0.baseAddress, &count) }
        guard result == .success else { throw NSError(domain: "CleaningResourceProbe", code: 3) }
        let owned = taps.prefix(Int(count)).filter { $0.tappingProcess == pid }.map {
            ["id": $0.eventTapID, "enabled": $0.enabled, "mask": $0.eventsOfInterest,
             "options": $0.options.rawValue] as [String: Any]
        }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid }
            .map { item in
                ["title": item[kCGWindowName as String] ?? "",
                 "layer": item[kCGWindowLayer as String] ?? -1,
                 "bounds": item[kCGWindowBounds as String] ?? [:]] as [String: Any]
            }
        let screens = NSScreen.screens.map {
            ["name": $0.localizedName, "x": $0.frame.minX, "y": $0.frame.minY,
             "width": $0.frame.width, "height": $0.frame.height] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject:
            ["pid": pid, "taps": owned, "windows": windows, "screens": screens],
            options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
