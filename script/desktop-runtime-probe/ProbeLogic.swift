import Foundation

enum ProbeError: Error, LocalizedError {
    case failure(String)
    var errorDescription: String? { switch self { case let .failure(message): message } }
}

enum ProbePolicy {
    // User updated the plan's development target on 2026-09-30. This is NOT
    // a production supported-build list, and deliberately admits no old build.
    static let developmentBuild = "26A434"
    static func permitsMutation(build: String) -> Bool { build == developmentBuild }
    static func validHelper(targetPID: Int32, observedPID: Int32, targetConnection: Int32,
                            observedConnection: Int32, controllerPID: Int32) -> Bool {
        targetPID > 0 && targetPID != controllerPID && targetPID == observedPID
            && targetConnection > 0 && targetConnection == observedConnection
    }
    static func isDesktopCandidate(verifiedFinder: Bool, layer: Int32, desktopLayer: Int32,
                                   bounds: [Double], display: [Double]) -> Bool {
        verifiedFinder && layer == desktopLayer && bounds.count == 4 && display.count == 4
            && zip(bounds, display).allSatisfy { abs($0 - $1) <= 2 }
    }
}

struct WindowState: Codable, Equatable {
    let alpha: Float
    let ordered: UInt8
    let alphaError: Int32
    let orderError: Int32

    var readable: Bool { alphaError == 0 && orderError == 0 && ordered <= 1 && alpha >= 0 && alpha <= 1 }
    func matches(_ other: WindowState) -> Bool {
        readable && other.readable && abs(alpha - other.alpha) < 0.001 && ordered == other.ordered
    }
    // Ordered-out is the condition under test; alpha alone would leave an
    // invisible window in the ordering / interaction path.
    var hidden: Bool { readable && ordered == 0 }
}

func foreignControlStatus(original: WindowState, observations: [WindowState],
                          ownerBeforeRestore: WindowState, environmentPreserved: Bool) -> String {
    // A successful return code with unchanged state is not a usable capability.
    guard environmentPreserved, !observations.isEmpty,
          observations.allSatisfy({ $0.matches(original) }), ownerBeforeRestore.matches(original) else {
        return "INCOMPLETE_REQUIRES_REVIEW"
    }
    return "NO_GO_DIRECT_CROSS_PROCESS_CONTROL"
}

func saveJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(value).write(to: url, options: .atomic)
}

func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
    try JSONDecoder().decode(type, from: Data(contentsOf: url))
}
