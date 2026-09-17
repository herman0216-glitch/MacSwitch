import AppKit
import Foundation

/// Observe real workspace sleep/wake notifications without changing power state.
@main
enum SleepEventProbe {
    @MainActor static func main() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [(Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "willSleep"),
            (NSWorkspace.didWakeNotification, "didWake"),
            (NSWorkspace.screensDidSleepNotification, "screensDidSleep"),
            (NSWorkspace.screensDidWakeNotification, "screensDidWake")
        ]
        let observers = names.map { name, label in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in emit(label) }
        }
        emit("started")
        RunLoop.main.run(until: Date().addingTimeInterval(240))
        for observer in observers { center.removeObserver(observer) }
        emit("finished")
    }

    private static func emit(_ event: String) {
        let row = ["event": event, "date": Date().ISO8601Format()]
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(10)
        FileHandle.standardOutput.write(data)
    }
}
