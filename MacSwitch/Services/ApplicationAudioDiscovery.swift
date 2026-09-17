import AppKit
import CoreAudio
import Darwin

struct DiscoveredAudioApplication: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let bundleURL: URL?
    let processObjectIDs: [AudioObjectID]
    let unsupportedReason: String?
}

@MainActor
final class ApplicationAudioDiscovery {
    private struct Group {
        let name: String
        let bundleURL: URL?
        var processes: [AudioObjectID]
        var reasons: Set<String>
    }

    func discover(defaultDevice: AudioObjectID) -> [DiscoveredAudioApplication] {
        guard let processes = try? AudioHAL.objectIDs(AudioObjectID(kAudioObjectSystemObject),
                                                      selector: kAudioHardwarePropertyProcessObjectList) else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownURL = Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
        var groups: [String: Group] = [:]
        for object in processes {
            guard let pid = try? AudioHAL.value(object, selector: kAudioProcessPropertyPID, initial: pid_t(0)),
                  pid > 0, pid != ownPID,
                  let active = try? AudioHAL.value(object, selector: kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)),
                  active != 0 else { continue }
            let running = NSRunningApplication(processIdentifier: pid)
            let executable = executableURL(pid: pid) ?? running?.executableURL
            // Browser audio helpers have nested .app bundles. The outer enclosing app owns their sound.
            let owner = executable.flatMap(outerApplicationURL) ?? running?.bundleURL
            let bundleURL = owner?.resolvingSymlinksInPath().standardizedFileURL
            if bundleURL == ownURL { continue }
            let bundle = bundleURL.flatMap(Bundle.init(url:))
            let processBundle = try? AudioHAL.string(object, selector: kAudioProcessPropertyBundleID)
            let bundleID = bundle?.bundleIdentifier ?? running?.bundleIdentifier ?? processBundle
            if let bundleID, bundleID == Bundle.main.bundleIdentifier { continue }
            let identifier = bundleURL?.path ?? bundleID ?? "process:\(pid)"
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? running?.localizedName ?? executable?.lastPathComponent ?? "音频进程 \(pid)"
            let devices = try? AudioHAL.objectIDs(object, selector: kAudioProcessPropertyDevices,
                                                  scope: kAudioDevicePropertyScopeOutput)
            var reasons: Set<String> = []
            if devices == nil || devices?.isEmpty == true {
                reasons.insert("无法确认输出路由，保留原声。")
            } else if devices != [defaultDevice] {
                reasons.insert("该应用使用其他输出路由，保留原声。")
            }
            if bundleURL == nil && bundleID == nil {
                reasons.insert("无法确认所属应用，保留原声。")
            }
            if var group = groups[identifier] {
                group.processes.append(object)
                group.reasons.formUnion(reasons)
                groups[identifier] = group
            } else {
                groups[identifier] = Group(name: name, bundleURL: bundleURL, processes: [object], reasons: reasons)
            }
        }
        return groups.map { identifier, group in
            DiscoveredAudioApplication(id: identifier, name: group.name, bundleURL: group.bundleURL,
                                       processObjectIDs: group.processes.sorted(),
                                       unsupportedReason: group.reasons.isEmpty ? nil : group.reasons.sorted().joined(separator: " "))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func executableURL(pid: pid_t) -> URL? {
        var bytes = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = bytes.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        guard length > 0 else { return nil }
        let path = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }

    private func outerApplicationURL(_ executable: URL) -> URL? {
        var cursor = executable.resolvingSymlinksInPath().standardizedFileURL
        var outermost: URL?
        while cursor.path != "/" {
            if cursor.pathExtension.caseInsensitiveCompare("app") == .orderedSame { outermost = cursor }
            cursor.deleteLastPathComponent()
        }
        return outermost
    }
}
