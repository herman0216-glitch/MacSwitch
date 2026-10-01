import Foundation
import Testing
@testable import MacSwitch

@MainActor
struct DesktopFileHiderTests {
    @Test func hidesOnlyVisibleItemsAndRestoresExactlyThose() throws {
        let files = FakeDesktopFileBackend(items: ["a.txt": false, "Folder": false, "mine.txt": true, ".DS_Store": false])
        let hider = DesktopFileHider(backend: files)

        try hider.hideAll()
        #expect(files.hidden == ["a.txt": true, "Folder": true, "mine.txt": true, ".DS_Store": false])
        #expect(files.manifest?.items.map(\.path).sorted() == [files.path("Folder"), files.path("a.txt")])

        try hider.restoreAll()
        #expect(files.hidden == ["a.txt": false, "Folder": false, "mine.txt": true, ".DS_Store": false])
        #expect(files.manifest == nil)
    }

    @Test func repeatedHideDoesNotDuplicateEntries() throws {
        let files = FakeDesktopFileBackend(items: ["a.txt": false])
        let hider = DesktopFileHider(backend: files)
        try hider.hideAll()
        try hider.hideAll()
        #expect(files.manifest?.items.count == 1)
    }

    @Test func failedFlagWriteRollsBackThisCallAndManifest() {
        let files = FakeDesktopFileBackend(items: ["a": false, "b": false, "c": false])
        files.failSetHidden = ["b"]
        let hider = DesktopFileHider(backend: files)

        #expect(throws: SwitchFailure.self) { try hider.hideAll() }
        #expect(files.hidden.values.allSatisfy { !$0 })
        #expect(files.manifest == nil)
    }

    @Test func movedItemIsRestoredThroughBookmark() throws {
        let files = FakeDesktopFileBackend(items: ["a.txt": false])
        let hider = DesktopFileHider(backend: files)
        try hider.hideAll()
        files.move("a.txt", to: "renamed.txt")

        try hider.restoreAll()
        #expect(files.hidden == ["renamed.txt": false])
        #expect(files.manifest == nil)
    }

    @Test func deletedItemIsDroppedAndUnrestorableItemIsKept() throws {
        let files = FakeDesktopFileBackend(items: ["gone": false, "stuck": false, "ok": false])
        let hider = DesktopFileHider(backend: files)
        try hider.hideAll()
        files.hidden["gone"] = nil
        files.failSetHidden = ["stuck"]

        #expect(throws: SwitchFailure.self) { try hider.restoreAll() }
        #expect(files.hidden["ok"] == false)
        #expect(files.manifest?.items.map(\.path) == [files.path("stuck")])
    }

    @Test func watcherHidesNewItemsOnlyWhileWatching() throws {
        let files = FakeDesktopFileBackend(items: ["a": false])
        let hider = DesktopFileHider(backend: files)
        try hider.hideAll()
        hider.startWatching()

        files.hidden["new.png"] = false
        files.trigger()
        #expect(files.hidden["new.png"] == true)
        #expect(files.manifest?.items.contains { $0.path == files.path("new.png") } == true)

        hider.stopWatching()
        files.hidden["later.png"] = false
        files.trigger()
        #expect(files.hidden["later.png"] == false)
    }

    @Test func serviceKeepsItemsHiddenAndRestoresOnDisable() async throws {
        let prefs = FakeWindowManagerBackend()
        let files = FakeDesktopFileBackend(items: ["a": false, "own": true])
        let service = DesktopService(backend: prefs, files: DesktopFileHider(backend: files), verifiedBuilds: ["26A428"])

        let on = try await service.setEnabled(true)
        #expect(on.isEnabled)
        #expect(prefs.state == .target(hidden: true))
        #expect(files.hidden == ["a": true, "own": true])
        #expect(files.isWatching)

        let off = try await service.setEnabled(false)
        #expect(!off.isEnabled)
        #expect(prefs.state == .target(hidden: false))
        #expect(files.hidden == ["a": false, "own": true])
        #expect(!files.isWatching)
    }

    @Test func serviceRollsBackPreferencesWhenFileHidingFails() async {
        let prefs = FakeWindowManagerBackend()
        let files = FakeDesktopFileBackend(items: ["a": false])
        files.failSetHidden = ["a"]
        let service = DesktopService(backend: prefs, files: DesktopFileHider(backend: files), verifiedBuilds: ["26A428"])

        await #expect(throws: SwitchFailure.self) { try await service.setEnabled(true) }
        #expect(prefs.state == DesktopPreferenceState(standardHideDesktopIcons: nil, hideDesktop: nil))
        #expect(files.hidden == ["a": false])
        #expect(!files.isWatching)
    }

    @Test func relaunchWithManifestResumesWatching() async throws {
        let prefs = FakeWindowManagerBackend()
        prefs.state = .target(hidden: true)
        let files = FakeDesktopFileBackend(items: ["a": true])
        files.manifest = DesktopHiddenManifest(items: [DesktopHiddenItem(path: files.path("a"))])
        let service = DesktopService(backend: prefs, files: DesktopFileHider(backend: files), verifiedBuilds: ["26A428"])

        #expect(try await service.read().isEnabled)
        #expect(files.isWatching)
        files.hidden["b"] = false
        files.trigger()
        #expect(files.hidden["b"] == true)
    }

    @Test func preferencesWithoutManifestAreReportedAsTemporary() async throws {
        let prefs = FakeWindowManagerBackend()
        prefs.state = .target(hidden: true)
        let files = FakeDesktopFileBackend(items: ["a": false])
        let service = DesktopService(backend: prefs, files: DesktopFileHider(backend: files), verifiedBuilds: ["26A428"])

        let state = try await service.read()
        #expect(!state.isEnabled)
        #expect(state.detail == "仅系统临时隐藏，重新开启即可持续隐藏")
        #expect(!files.isWatching)
        #expect(files.hidden == ["a": false])
    }

    @Test func showAllFilesIsExplained() async throws {
        let prefs = FakeWindowManagerBackend()
        let files = FakeDesktopFileBackend(items: [:])
        files.showAll = true
        let service = DesktopService(backend: prefs, files: DesktopFileHider(backend: files), verifiedBuilds: ["26A428"])

        #expect(try await service.setEnabled(true).detail == "Finder 已开启显示隐藏文件，桌面项目仍会显示")
    }
}

/// In-memory Desktop keyed by item name; the value is the `UF_HIDDEN` flag.
@MainActor final class FakeDesktopFileBackend: DesktopFileBackend {
    var hidden: [String: Bool]
    var manifest: DesktopHiddenManifest?
    var failSetHidden: Set<String> = []
    var showAll = false
    private(set) var isWatching = false
    private var onChange: (@MainActor () -> Void)?
    private var moves: [String: String] = [:]
    private let root = URL(fileURLWithPath: "/fake/Desktop")

    init(items: [String: Bool] = [:]) { hidden = items }

    func path(_ name: String) -> String { root.appending(path: name).path }
    private func name(_ url: URL) -> String { url.lastPathComponent }

    func move(_ from: String, to: String) {
        hidden[to] = hidden.removeValue(forKey: from)
        moves[from] = to
    }

    func trigger() { onChange?() }

    func contents() throws -> [URL] { hidden.keys.sorted().map { root.appending(path: $0) } }
    func isHidden(_ url: URL) throws -> Bool {
        guard let value = hidden[name(url)] else { throw SwitchFailure.failed("不存在") }
        return value
    }
    func setHidden(_ value: Bool, at url: URL) throws {
        if failSetHidden.contains(name(url)) { throw SwitchFailure.failed("模拟写入失败") }
        guard hidden[name(url)] != nil else { throw SwitchFailure.failed("不存在") }
        hidden[name(url)] = value
    }
    func exists(_ url: URL) -> Bool { url.deletingLastPathComponent().path == root.path && hidden[name(url)] != nil }
    func bookmark(for url: URL) -> Data? { Data(name(url).utf8) }
    func resolve(_ bookmark: Data) -> URL? {
        let original = String(decoding: bookmark, as: UTF8.self)
        return moves[original].map { root.appending(path: $0) }
    }
    func loadManifest() throws -> DesktopHiddenManifest? { manifest }
    func saveManifest(_ manifest: DesktopHiddenManifest?) throws { self.manifest = manifest }
    func showsAllFiles() -> Bool { showAll }
    func startWatching(_ onChange: @escaping @MainActor () -> Void) {
        isWatching = true
        self.onChange = onChange
    }
    func stopWatching() {
        isWatching = false
        onChange = nil
    }
}

@MainActor final class FakeWindowManagerBackend: DesktopBackend {
    var systemBuild = "26A428"
    var state = DesktopPreferenceState(standardHideDesktopIcons: nil, hideDesktop: nil)
    func preferences() -> DesktopPreferenceState { state }
    func legacyCreateDesktop() -> Bool? { true }
    func write(_ value: Bool?, for key: DesktopPreferenceKey) throws {
        switch key {
        case .standardHideDesktopIcons: state.standardHideDesktopIcons = value
        case .hideDesktop: state.hideDesktop = value
        }
    }
}
