import Foundation
import Darwin

struct DesktopHiddenItem: Codable, Equatable, Sendable {
    var path: String
    var bookmark: Data?
}

/// Items MacSwitch itself flagged hidden. Items that were already hidden are never recorded,
/// so restoring only clears flags this app set.
struct DesktopHiddenManifest: Codable, Equatable, Sendable {
    var items: [DesktopHiddenItem] = []
}

@MainActor
protocol DesktopFileBackend: AnyObject {
    func contents() throws -> [URL]
    func isHidden(_ url: URL) throws -> Bool
    func setHidden(_ hidden: Bool, at url: URL) throws
    func exists(_ url: URL) -> Bool
    func bookmark(for url: URL) -> Data?
    func resolve(_ bookmark: Data) -> URL?
    func loadManifest() throws -> DesktopHiddenManifest?
    /// Passing `nil` removes the manifest.
    func saveManifest(_ manifest: DesktopHiddenManifest?) throws
    func showsAllFiles() -> Bool
    func startWatching(_ onChange: @escaping @MainActor () -> Void)
    func stopWatching()
}

@MainActor
final class DesktopFileHider {
    private let backend: any DesktopFileBackend
    private(set) var isWatching = false
    private(set) var lastWatchError: String?

    init(backend: any DesktopFileBackend = FileSystemDesktopBackend()) {
        self.backend = backend
    }

    func isActive() throws -> Bool { try backend.loadManifest() != nil }
    func showsAllFiles() -> Bool { backend.showsAllFiles() }

    /// Hides every visible top-level Desktop item. On failure, flags set by this call are cleared
    /// and the manifest returns to its previous value.
    func hideAll() throws {
        let previous = try backend.loadManifest()
        var manifest = previous ?? DesktopHiddenManifest()
        let known = Set(manifest.items.map(\.path))
        var pending: [URL] = []
        for url in try backend.contents() where !url.lastPathComponent.hasPrefix(".") {
            if try !backend.isHidden(url) { pending.append(url) }
        }
        for url in pending where !known.contains(url.path) {
            manifest.items.append(DesktopHiddenItem(path: url.path, bookmark: backend.bookmark(for: url)))
        }
        // Record before flagging so a crash still leaves a restorable list.
        try backend.saveManifest(manifest)

        var flagged: [URL] = []
        do {
            for url in pending {
                try backend.setHidden(true, at: url)
                flagged.append(url)
                guard try backend.isHidden(url) else {
                    throw SwitchFailure.failed("系统未确认“\(url.lastPathComponent)”已隐藏。")
                }
            }
        } catch {
            for url in flagged.reversed() { try? backend.setHidden(false, at: url) }
            try? backend.saveManifest(previous)
            throw error
        }
    }

    /// Clears the flags recorded in the manifest. Items that cannot be restored stay in the manifest.
    func restoreAll() throws {
        guard let manifest = try backend.loadManifest() else { return }
        var remaining: [DesktopHiddenItem] = []
        var errors: [String] = []
        for item in manifest.items {
            var url = URL(fileURLWithPath: item.path)
            if !backend.exists(url), let bookmark = item.bookmark, let moved = backend.resolve(bookmark) {
                url = moved
            }
            // Deleted while hidden: nothing left to restore.
            guard backend.exists(url) else { continue }
            do { try backend.setHidden(false, at: url) }
            catch {
                remaining.append(item)
                errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        try backend.saveManifest(remaining.isEmpty ? nil : DesktopHiddenManifest(items: remaining))
        if !errors.isEmpty {
            throw SwitchFailure.failed("部分桌面项目未能恢复显示：\(errors.joined(separator: "；"))。")
        }
    }

    func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        backend.startWatching { [weak self] in self?.desktopChanged() }
        desktopChanged()
    }

    func stopWatching() {
        guard isWatching else { return }
        isWatching = false
        backend.stopWatching()
    }

    private func desktopChanged() {
        guard isWatching else { return }
        do {
            try hideAll()
            lastWatchError = nil
        } catch {
            lastWatchError = error.localizedDescription
        }
    }
}

@MainActor
final class FileSystemDesktopBackend: DesktopFileBackend {
    private let desktopURL: URL
    private let manifestURL: URL
    private var source: (any DispatchSourceFileSystemObject)?
    private var pendingScan: DispatchWorkItem?
    private var onChange: (@MainActor () -> Void)?

    init(fileManager: FileManager = .default) {
        desktopURL = fileManager.homeDirectoryForCurrentUser.appending(path: "Desktop", directoryHint: .isDirectory)
        let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        manifestURL = support.appending(path: "MacSwitch/desktop-hidden.json")
    }

    func contents() throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: desktopURL, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw SwitchFailure.unauthorized("需要访问“桌面”文件夹的权限。请在 系统设置 › 隐私与安全性 › 文件与文件夹 中允许 MacSwitch。")
        }
    }

    func isHidden(_ url: URL) throws -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixFailure("读取", url) }
        return info.st_flags & UInt32(UF_HIDDEN) != 0
    }

    func setHidden(_ hidden: Bool, at url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw posixFailure("读取", url) }
        let flags = hidden ? info.st_flags | UInt32(UF_HIDDEN) : info.st_flags & ~UInt32(UF_HIDDEN)
        guard lchflags(url.path, flags) == 0 else { throw posixFailure("设置", url) }
    }

    func exists(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0
    }

    func bookmark(for url: URL) -> Data? {
        // Bookmarks resolve through symlinks; the path is enough for those.
        guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { return nil }
        return try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ bookmark: Data) -> URL? {
        var stale = false
        return try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
    }

    func loadManifest() throws -> DesktopHiddenManifest? {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return nil }
        do {
            return try JSONDecoder().decode(DesktopHiddenManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            throw SwitchFailure.failed("无法读取桌面隐藏记录（\(manifestURL.path)）：\(error.localizedDescription)")
        }
    }

    func saveManifest(_ manifest: DesktopHiddenManifest?) throws {
        do {
            guard let manifest else {
                if FileManager.default.fileExists(atPath: manifestURL.path) {
                    try FileManager.default.removeItem(at: manifestURL)
                }
                return
            }
            try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: .atomic)
        } catch {
            throw SwitchFailure.failed("无法保存桌面隐藏记录：\(error.localizedDescription)")
        }
    }

    func showsAllFiles() -> Bool {
        let domain = "com.apple.finder" as CFString
        CFPreferencesAppSynchronize(domain)
        switch CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString, domain) {
        case let value as Bool: return value
        case let value as String: return ["1", "yes", "true"].contains(value.lowercased())
        default: return false
        }
    }

    func startWatching(_ onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        openSource()
    }

    func stopWatching() {
        onChange = nil
        pendingScan?.cancel()
        pendingScan = nil
        source?.cancel()
        source = nil
    }

    private func openSource() {
        source?.cancel()
        source = nil
        let descriptor = open(desktopURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // The Desktop folder may be briefly missing (for example during iCloud setup).
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                MainActor.assumeIsolated { if self?.onChange != nil { self?.openSource() } }
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                if !source.data.isDisjoint(with: [.delete, .rename]) { self.openSource() }
                self.scheduleScan()
            }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange?() }
        }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func posixFailure(_ action: String, _ url: URL) -> SwitchFailure {
        let code = errno
        let message = String(cString: strerror(code))
        if code == EPERM || code == EACCES {
            return .unauthorized("无法\(action)“\(url.lastPathComponent)”的隐藏状态（\(message)）。请在 系统设置 › 隐私与安全性 › 文件与文件夹 中允许 MacSwitch 访问“桌面”。")
        }
        return .failed("无法\(action)“\(url.lastPathComponent)”的隐藏状态（\(message)）。")
    }
}
