import AppKit
import Observation

@MainActor @Observable
final class AppModel {
    static let shared = AppModel()
    let preferences: PreferencesStore
    let coordinator: SwitchCoordinator
    let keepAwake: KeepAwakeService
    let cleaning: CleaningService
    let volume = VolumeControlService()
    let loginItem = LoginItemService()
    let hotKeys: HotKeyService
    private(set) var shortcutErrors: [FeatureID: String] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var refreshTimer: Timer?

    init() {
        let preferences = PreferencesStore()
        self.preferences = preferences
        let awake = KeepAwakeService()
        awake.duration = preferences.value.awakeDuration
        keepAwake = awake
        let cleaning = CleaningService()
        self.cleaning = cleaning
        let coordinator = SwitchCoordinator(services: [AppearanceService(), DesktopService(), awake, AudioMuteService(input: false), AudioMuteService(input: true), cleaning, volume])
        self.coordinator = coordinator
        hotKeys = HotKeyService { [weak coordinator] id in coordinator?.toggle(id) }
        cleaning.onSessionChange = { [weak hotKeys] active in hotKeys?.isSuspended = active }
        for id in FeatureID.allCases {
            do { try hotKeys.register(preferences.value.shortcuts[id], for: id) }
            catch { shortcutErrors[id] = error.localizedDescription }
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak coordinator] _ in
            Task { @MainActor in coordinator?.refreshAll() }
        })
        // Finder has no documented preference-change notification. This low-rate
        // read-only fallback also reconciles missed notifications after sleep.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak coordinator] _ in
            Task { @MainActor in coordinator?.refreshAll() }
        }
        coordinator.refreshAll()
    }

    func record(_ shortcut: RecordedShortcut?, for feature: FeatureID) throws {
        try hotKeys.register(shortcut, for: feature)
        preferences.setShortcut(shortcut, for: feature)
        shortcutErrors[feature] = nil
    }
    func setDuration(_ duration: AwakeDuration) {
        preferences.setAwakeDuration(duration)
        keepAwake.duration = duration
        coordinator.restartIfEnabled(.keepAwake)
    }
    func beginStopping() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        hotKeys.shutdown()
        cleaning.shutdown()
        volume.shutdown()
        coordinator.beginStopping()
        keepAwake.shutdown()
    }
    func shutdown() {
        beginStopping()
        coordinator.shutdown()
    }
}
