import Foundation

struct AudioGainResult: Equatable, Sendable {
    let linearGain: Float
    let isAmplificationLimited: Bool
    let usesApproximateCurve: Bool
}

enum AudioGain {
    static let maximumBoostDecibels: Float = 12

    /// Percentages describe a target on the device volume curve, before its master attenuation.
    static func calculate(
        targetPercent: Double,
        outputPercent: Double,
        muted: Bool = false,
        decibels: (Float) -> Float?
    ) -> AudioGainResult {
        let target = Float(min(100, max(0, targetPercent.isFinite ? targetPercent : 0)) / 100)
        let output = Float(min(100, max(0, outputPercent.isFinite ? outputPercent : 0)) / 100)
        guard !muted, target > 0, output > 0 else {
            return AudioGainResult(linearGain: 0, isAmplificationLimited: false, usesApproximateCurve: false)
        }
        let targetDB = decibels(target)
        let outputDB = decibels(output)
        let exact = targetDB?.isFinite == true && outputDB?.isFinite == true
        let requestedDB: Float
        if exact, let targetDB, let outputDB {
            requestedDB = targetDB - outputDB
        } else {
            requestedDB = 20 * log10(target / output)
        }
        let limited = requestedDB > maximumBoostDecibels
        let gain = pow(10, min(maximumBoostDecibels, requestedDB) / 20)
        return AudioGainResult(linearGain: gain.isFinite ? gain : 0,
                               isAmplificationLimited: limited,
                               usesApproximateCurve: !exact)
    }
}
