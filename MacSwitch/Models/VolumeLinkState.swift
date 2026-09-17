import Foundation

/// Targets are session-only percentages. Feed this reducer actual, ordered system
/// readbacks, never optimistic slider values or mute-derived zeroes.
struct VolumeLinkState: Equatable, Sendable {
    private(set) var outputVolume: Double
    private(set) var isMuted: Bool
    private(set) var applicationTargets: [String: Double] = [:]

    init(outputVolume: Double = 0, isMuted: Bool = false) {
        self.outputVolume = Self.clamp(outputVolume)
        self.isMuted = isMuted
    }

    var isOutputSilent: Bool { isMuted || outputVolume == 0 }

    /// Clamping each transition (rather than retaining a hidden offset) means a
    /// target that hits a boundary responds immediately when direction reverses.
    mutating func applySystemOutput(_ value: Double, isMuted: Bool) {
        guard value.isFinite else { return }
        let confirmed = Self.clamp(value)
        let delta = confirmed - outputVolume
        outputVolume = confirmed
        self.isMuted = isMuted
        guard delta != 0 else { return }
        for (id, target) in applicationTargets {
            applicationTargets[id] = Self.clamp(target + delta)
        }
    }

    /// Rediscovery must not overwrite an independently adjusted target.
    @discardableResult
    mutating func addApplication(_ id: String) -> Double {
        if let current = applicationTargets[id] { return current }
        applicationTargets[id] = outputVolume
        return outputVolume
    }

    mutating func setApplicationVolume(_ value: Double, for id: String) {
        guard value.isFinite, applicationTargets[id] != nil else { return }
        applicationTargets[id] = Self.clamp(value)
    }

    mutating func removeApplication(_ id: String) {
        applicationTargets.removeValue(forKey: id)
    }

    mutating func reset(outputVolume: Double = 0, isMuted: Bool = false) {
        self = Self(outputVolume: outputVolume, isMuted: isMuted)
    }

    static func clamp(_ value: Double) -> Double {
        value.isFinite ? min(100, max(0, value)) : 0
    }
}
