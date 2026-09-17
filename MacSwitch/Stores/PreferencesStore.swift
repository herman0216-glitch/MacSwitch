import Foundation
import Observation

struct AppPreferences: Codable, Equatable {
    var version = 1
    var order: [FeatureID] = FeatureID.allCases
    var hidden: Set<FeatureID> = []
    var shortcuts: [FeatureID: RecordedShortcut] = [:]
    var awakeDuration: AwakeDuration = .thirtyMinutes

    mutating func normalize() {
        var seen = Set<FeatureID>()
        order = order.filter { seen.insert($0).inserted }
        order.append(contentsOf: FeatureID.allCases.filter { !seen.contains($0) })
    }
}

@MainActor @Observable
final class PreferencesStore {
    static let storageKey = "MacSwitch.preferences.v1"
    private(set) var value: AppPreferences
    private(set) var warning: String?
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey) {
            if var decoded = try? JSONDecoder().decode(AppPreferences.self, from: data), decoded.version == 1 {
                decoded.normalize()
                value = decoded
            } else {
                value = AppPreferences()
                warning = "本地配置无法读取，已使用默认设置。原始配置保留到下次保存。"
            }
        } else { value = AppPreferences() }
    }

    var visibleFeatures: [FeatureID] { value.order.filter { !value.hidden.contains($0) } }
    func setVisible(_ visible: Bool, for feature: FeatureID) {
        if visible { value.hidden.remove(feature) } else { value.hidden.insert(feature) }
        save()
    }
    func setOrder(_ order: [FeatureID]) {
        value.order = order
        value.normalize()
        save()
    }
    func move(_ source: FeatureID, to destination: FeatureID) {
        guard source != destination else { return }
        var order = value.order
        guard let targetIndex = order.firstIndex(of: destination) else { return }
        order.removeAll { $0 == source }
        order.insert(source, at: min(targetIndex, order.count))
        setOrder(order)
    }
    func setShortcut(_ shortcut: RecordedShortcut?, for feature: FeatureID) {
        value.shortcuts[feature] = shortcut
        save()
    }
    func setAwakeDuration(_ duration: AwakeDuration) {
        value.awakeDuration = duration
        save()
    }
    private func save() {
        do {
            let encoded = try JSONEncoder().encode(value)
            defaults.set(encoded, forKey: Self.storageKey)
            warning = nil
        } catch { warning = "无法保存配置：\(error.localizedDescription)" }
    }
}
