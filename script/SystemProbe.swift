import Foundation
import IOKit.pwr_mgt

@main
struct SystemProbe {
    @MainActor static func main() async throws {
        let action = CommandLine.arguments.dropFirst().first ?? "read"
        switch action {
        case "read":
            for input in [false, true] {
                let service = AudioMuteService(input: input)
                print("\(service.id.rawValue): \(try await service.read())")
                service.shutdown()
            }
            print("appearance: \(try await AppearanceService().read())")
            print("desktop: \(try await DesktopService().read())")
        case "input-on", "input-off", "output-on", "output-off":
            let service = AudioMuteService(input: action.hasPrefix("input"))
            print("before: \(try await service.read())")
            print("after: \(try await service.setEnabled(action.hasSuffix("-on")))")
            service.shutdown()
        case "audio-cycle":
            for input in [false, true] {
                let service = AudioMuteService(input: input)
                let original = try await service.read()
                print("\(service.id.rawValue) original: \(original)")
                guard original.availability == .available else { service.shutdown(); continue }
                do {
                    for _ in 0..<3 {
                        print("changed: \(try await service.setEnabled(!original.isEnabled))")
                        try await Task.sleep(for: .milliseconds(400))
                        print("restored: \(try await service.setEnabled(original.isEnabled))")
                    }
                } catch {
                    _ = try? await service.setEnabled(original.isEnabled)
                    service.shutdown()
                    throw error
                }
                service.shutdown()
            }
        case "awake", "awake-crash":
            let service = KeepAwakeService()
            service.duration = .untilDisabled
            print("pid=\(ProcessInfo.processInfo.processIdentifier), started: \(try await service.setEnabled(true))")
            fflush(stdout)
            let seconds = action == "awake-crash" ? 120 : 8
            for _ in 0..<seconds { try await Task.sleep(for: .seconds(1)) }
            print("stopped: \(try await service.setEnabled(false))")
            service.shutdown()
        case "kernel-timeout":
            let backend = IOKitPowerBackend()
            let ids = try backend.create(timeout: 2)
            print("created 2-second kernel assertions: \(ids)")
            fflush(stdout)
            try await Task.sleep(for: .seconds(3))
            for id in ids {
                let exists = IOPMAssertionCopyProperties(id) != nil
                print("id=\(id) exists-after-timeout=\(exists)")
                guard !exists else { try backend.release(id); throw SwitchFailure.failed("Kernel timeout did not release assertion") }
                try backend.release(id)
            }
        default:
            throw SwitchFailure.failed("Usage: read | audio-cycle | input-on | input-off | output-on | output-off | awake | awake-crash | kernel-timeout")
        }
    }
}
