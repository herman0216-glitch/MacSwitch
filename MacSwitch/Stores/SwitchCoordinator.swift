import Foundation
import Observation
import OSLog

@MainActor @Observable
final class SwitchCoordinator {
    private(set) var states: [FeatureID: FeatureState] = [:]
    @ObservationIgnored private let services: [FeatureID: any SwitchService]
    @ObservationIgnored private var queues: [FeatureID: [Command]] = [:]
    @ObservationIgnored private var workers: [FeatureID: Task<Void, Never>] = [:]
    @ObservationIgnored private var failedCommands: [FeatureID: Command] = [:]
    @ObservationIgnored private var stopping = false
    @ObservationIgnored private let logger = Logger(subsystem: "local.herman.MacSwitch", category: "Switch")
    private enum Command { case toggle, set(Bool), refresh, restartIfEnabled }

    init(services: [any SwitchService]) {
        self.services = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
        for service in services {
            states[service.id] = FeatureState()
            let id = service.id
            service.onChange = { [weak self] in self?.refresh(id) }
        }
    }

    func state(_ id: FeatureID) -> FeatureState { states[id] ?? FeatureState() }
    func toggle(_ id: FeatureID) { enqueue(.toggle, for: id) }
    func setEnabled(_ value: Bool, for id: FeatureID) { enqueue(.set(value), for: id) }
    func restartIfEnabled(_ id: FeatureID) { enqueue(.restartIfEnabled, for: id) }
    func retry(_ id: FeatureID) { enqueue(failedCommands[id] ?? .refresh, for: id) }
    func refresh(_ id: FeatureID) { enqueue(.refresh, for: id) }
    func refreshAll() { for id in services.keys { refresh(id) } }
    var isBusy: Bool { !workers.isEmpty }

    private func enqueue(_ command: Command, for id: FeatureID) {
        guard !stopping, services[id] != nil else { return }
        if case .refresh = command,
           queues[id, default: []].contains(where: { if case .refresh = $0 { true } else { false } }) { return }
        queues[id, default: []].append(command)
        guard workers[id] == nil else { return }
        workers[id] = Task { [weak self] in await self?.drain(id) }
    }

    private func drain(_ id: FeatureID) async {
        guard let service = services[id] else { workers[id] = nil; return }
        while !queues[id, default: []].isEmpty {
            let command = queues[id]!.removeFirst()
            if case .refresh = command {
                do {
                    let snapshot = try await service.read()
                    let previous = states[id]?.snapshot
                    states[id]?.snapshot = snapshot
                    states[id]?.hasRead = true
                    switch snapshot.availability {
                    case .unsupported(let reason): states[id]?.phase = .unsupported(reason)
                    case .unauthorized(let reason): states[id]?.phase = .unauthorized(reason)
                    case .available:
                        if case .refresh = failedCommands[id] {
                            failedCommands[id] = nil
                            states[id]?.phase = .idle
                        } else if case .unsupported = states[id]?.phase { states[id]?.phase = .idle }
                        else if previous != snapshot, states[id]?.phase == .succeeded { states[id]?.phase = .idle }
                    }
                } catch {
                    if failedCommands[id] == nil { failedCommands[id] = .refresh }
                    apply(error, to: id)
                }
                continue
            }
            states[id]?.phase = .working
            var retryCommand = command
            do {
                let before = try await service.read()
                let requested: Bool
                switch command {
                case .toggle: requested = !before.isEnabled
                case .set(let enabled): requested = enabled
                case .restartIfEnabled:
                    guard before.isEnabled else {
                        states[id]?.snapshot = before
                        states[id]?.hasRead = true
                        states[id]?.phase = .idle
                        continue
                    }
                    requested = true
                case .refresh: continue
                }
                retryCommand = .set(requested)
                let after = try await service.setEnabled(requested)
                guard after.isEnabled == requested else { throw SwitchFailure.failed("系统状态未确认，请重试。") }
                states[id]?.snapshot = after
                states[id]?.hasRead = true
                states[id]?.phase = .succeeded
                failedCommands[id] = nil
                logger.info("feature=\(id.rawValue, privacy: .public) enabled=\(requested) success")
            } catch {
                failedCommands[id] = retryCommand
                // Restore the UI from the system, even if the write partially succeeded.
                if let actual = try? await service.read() {
                    states[id]?.snapshot = actual
                    states[id]?.hasRead = true
                }
                apply(error, to: id)
                logger.error("feature=\(id.rawValue, privacy: .public) failed")
            }
        }
        workers[id] = nil
    }

    private func apply(_ error: Error, to id: FeatureID) {
        switch error {
        case SwitchFailure.unauthorized(let reason): states[id]?.phase = .unauthorized(reason)
        case SwitchFailure.unsupported(let reason): states[id]?.phase = .unsupported(reason)
        default: states[id]?.phase = .failed(error.localizedDescription)
        }
    }

    func waitUntilIdle() async {
        while let worker = workers.values.first { await worker.value }
    }

    func shutdown() {
        beginStopping()
        for service in services.values { service.shutdown() }
    }

    func beginStopping() {
        stopping = true
        // Let an in-flight operation finish (including Finder rollback), but
        // discard commands that have not started after the user chose Quit.
        queues.removeAll()
    }
}
