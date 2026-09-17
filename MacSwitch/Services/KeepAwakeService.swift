import Foundation
import IOKit.pwr_mgt

@MainActor
protocol PowerAssertionBackend: AnyObject {
    func create(timeout: TimeInterval?) throws -> [IOPMAssertionID]
    func isActive(_ id: IOPMAssertionID) throws -> Bool
    func release(_ id: IOPMAssertionID) throws
}

@MainActor
final class IOKitPowerBackend: PowerAssertionBackend {
    func create(timeout: TimeInterval?) throws -> [IOPMAssertionID] {
        var ids: [IOPMAssertionID] = []
        do {
            for type in [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep] {
                var properties: [String: Any] = [
                    kIOPMAssertionTypeKey: type,
                    kIOPMAssertionNameKey: "MacSwitch - Keep Awake",
                    kIOPMAssertionLevelKey: kIOPMAssertionLevelOn,
                    kIOPMAssertionHumanReadableReasonKey: "在选定时间内保持系统与屏幕唤醒"
                ]
                if let timeout {
                    properties[kIOPMAssertionTimeoutKey] = timeout
                    properties[kIOPMAssertionTimeoutActionKey] = kIOPMAssertionTimeoutActionRelease
                }
                var id: IOPMAssertionID = 0
                let status = IOPMAssertionCreateWithProperties(properties as CFDictionary, &id)
                guard status == kIOReturnSuccess else { throw SwitchFailure.failed("无法开启防休眠（\(status)）。") }
                ids.append(id)
            }
            return ids
        } catch {
            for id in ids { try? release(id) }
            throw error
        }
    }

    func isActive(_ id: IOPMAssertionID) throws -> Bool {
        guard let unmanaged = IOPMAssertionCopyProperties(id),
              let properties = unmanaged.takeRetainedValue() as? [String: Any] else {
            throw SwitchFailure.failed("无法确认防休眠状态，请关闭后重试。")
        }
        return properties[kIOPMAssertionLevelKey] as? Int == kIOPMAssertionLevelOn
    }

    func release(_ id: IOPMAssertionID) throws {
        let result = IOPMAssertionRelease(id)
        // The OS returns badArgument for an assertion it already released at
        // its kernel timeout. IDs here were returned by our own create call.
        guard result == kIOReturnSuccess || result == kIOReturnBadArgument || result == kIOReturnNotFound else {
            throw SwitchFailure.failed("防休眠释放失败（\(result)），请重试或退出应用。")
        }
    }
}

@MainActor
final class KeepAwakeService: SwitchService {
    let id: FeatureID = .keepAwake
    var onChange: (@MainActor () -> Void)?
    var duration: AwakeDuration = .thirtyMinutes
    private let backend: any PowerAssertionBackend
    private let now: @MainActor () -> TimeInterval
    private var assertions: [IOPMAssertionID] = []
    private var deadline: TimeInterval?
    private var timer: Timer?
    private var releaseError: String?

    init(backend: any PowerAssertionBackend = IOKitPowerBackend(), now: @escaping @MainActor () -> TimeInterval = KeepAwakeService.monotonicNow) {
        self.backend = backend
        self.now = now
    }

    static func monotonicNow() -> TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    func read() async throws -> SwitchSnapshot {
        if let deadline, now() >= deadline { try stop() }
        if assertions.isEmpty {
            deadline = nil
            timer?.invalidate()
            timer = nil
            return SwitchSnapshot(isEnabled: false, detail: "保持系统与屏幕唤醒")
        }
        // Keep ownership even when querying fails or an assertion is off, so
        // stop()/shutdown() can still release every acquired ID.
        let active = try assertions.map { try backend.isActive($0) }
        guard active.count == 2, active.allSatisfy({ $0 }) else {
            return SwitchSnapshot(isEnabled: active.contains(true), detail: "防休眠未完全生效，请关闭后重新开启。")
        }
        if let releaseError { return SwitchSnapshot(isEnabled: true, detail: releaseError) }
        if let deadline {
            let seconds = Int(ceil(max(0, deadline - now())))
            let text = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            return SwitchSnapshot(isEnabled: true, detail: "剩余 \(text)")
        }
        return SwitchSnapshot(isEnabled: true, detail: "保持唤醒，直到关闭")
    }

    func setEnabled(_ enabled: Bool) async throws -> SwitchSnapshot {
        if enabled {
            // A new duration deliberately starts a new session.
            try stop()
            assertions = try backend.create(timeout: duration.seconds)
            deadline = duration.seconds.map { now() + $0 }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.onChange?() }
            }
            if let timer { RunLoop.main.add(timer, forMode: .common) }
        } else {
            try stop()
        }
        return try await read()
    }

    private func stop() throws {
        releaseError = nil
        var remaining: [IOPMAssertionID] = []
        for assertion in assertions {
            do { try backend.release(assertion) }
            catch { remaining.append(assertion); releaseError = error.localizedDescription }
        }
        assertions = remaining
        if remaining.isEmpty {
            deadline = nil
            timer?.invalidate()
            timer = nil
        }
        if let releaseError { throw SwitchFailure.failed(releaseError) }
    }

    func shutdown() {
        try? stop()
        timer?.invalidate()
        timer = nil
        // IOKit also destroys process-owned assertions on abnormal process exit.
    }
}
