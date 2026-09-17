import Foundation
import Testing
@testable import MacSwitch

@MainActor
struct PreferencesTests {
    @Test func versionOneFiveSwitchConfigurationAddsNewFeaturesWithoutLosingSettings() throws {
        let name = "MacSwitchTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var legacy = AppPreferences()
        legacy.order = [.inputMute, .desktop, .appearance, .keepAwake, .outputMute]
        legacy.hidden = [.desktop]
        legacy.shortcuts[.keepAwake] = RecordedShortcut(keyCode: 40, modifiers: 768)
        defaults.set(try JSONEncoder().encode(legacy), forKey: PreferencesStore.storageKey)
        let restored = PreferencesStore(defaults: defaults)
        #expect(restored.value.order == legacy.order + [.cleaning, .volumeControl])
        #expect(restored.value.hidden == legacy.hidden)
        #expect(restored.value.shortcuts == legacy.shortcuts)
        #expect(restored.warning == nil)
    }
    @Test func defaultsAndReopenPreserveOnlyConfiguration() throws {
        let name = "MacSwitchTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PreferencesStore(defaults: defaults)
        #expect(store.visibleFeatures == FeatureID.allCases)
        #expect(store.value.shortcuts.isEmpty)
        #expect(store.value.awakeDuration == .thirtyMinutes)
        store.setVisible(false, for: .desktop)
        let order = Array(FeatureID.allCases.reversed())
        store.setOrder(order)
        let shortcut = RecordedShortcut(keyCode: 40, modifiers: 768)
        store.setShortcut(shortcut, for: .keepAwake)
        store.setAwakeDuration(.oneHour)
        let reopened = PreferencesStore(defaults: defaults)
        #expect(reopened.value == store.value)
        #expect(reopened.value.order == order)
        #expect(!reopened.visibleFeatures.contains(.desktop))
        #expect(reopened.value.shortcuts[.keepAwake] == shortcut)
    }

    @Test func malformedConfigurationFallsBackWithWarning() throws {
        let name = "MacSwitchTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("broken".utf8), forKey: PreferencesStore.storageKey)
        let store = PreferencesStore(defaults: defaults)
        #expect(store.value == AppPreferences())
        #expect(store.warning != nil)
        #expect(defaults.data(forKey: PreferencesStore.storageKey) == Data("broken".utf8))
    }

    @Test func orderNormalizationKeepsEachFeatureExactlyOnce() {
        var value = AppPreferences()
        value.order = [.desktop, .desktop, .appearance]
        value.normalize()
        #expect(value.order == [.desktop, .appearance] + FeatureID.allCases.filter { $0 != .desktop && $0 != .appearance })
    }

    @Test func dropMovesFeatureInBothDirectionsAndPersists() throws {
        let name = "MacSwitchTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = PreferencesStore(defaults: defaults)
        store.move(.keepAwake, to: .appearance)
        let addedFeatures = FeatureID.allCases.filter { ![.appearance, .desktop, .keepAwake, .outputMute, .inputMute].contains($0) }
        #expect(store.value.order == [.keepAwake, .appearance, .desktop, .outputMute, .inputMute] + addedFeatures)
        store.move(.appearance, to: .inputMute)
        #expect(store.value.order == [.keepAwake, .desktop, .outputMute, .inputMute, .appearance] + addedFeatures)
        #expect(PreferencesStore(defaults: defaults).value.order == store.value.order)
    }
}
