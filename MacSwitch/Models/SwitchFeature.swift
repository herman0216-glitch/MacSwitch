import Foundation

enum FeatureID: String, CaseIterable, Codable, Identifiable, Sendable {
    case appearance, desktop, keepAwake, outputMute, inputMute, cleaning, volumeControl
    var id: String { rawValue }
    var title: String {
        switch self {
        case .appearance: "深色模式"
        case .desktop: "隐藏桌面图标"
        case .keepAwake: "防休眠"
        case .outputMute: "声音静音"
        case .inputMute: "麦克风静音"
        case .cleaning: "屏幕键盘清洁"
        case .volumeControl: "音量控制"
        }
    }
    var symbol: String {
        switch self {
        case .appearance: "moon.fill"
        case .desktop: "desktopcomputer"
        case .keepAwake: "cup.and.saucer.fill"
        case .outputMute: "speaker.slash.fill"
        case .inputMute: "mic.slash.fill"
        case .cleaning: "sparkles.rectangle.stack"
        case .volumeControl: "slider.horizontal.3"
        }
    }
}

enum SwitchAvailability: Equatable, Sendable {
    case available
    case unsupported(String)
    case unauthorized(String)
}

struct SwitchSnapshot: Equatable, Sendable {
    var isEnabled: Bool
    var detail: String? = nil
    var availability: SwitchAvailability = .available
}

enum SwitchFailure: Error, LocalizedError, Equatable, Sendable {
    case failed(String)
    case unauthorized(String)
    case unsupported(String)
    var errorDescription: String? {
        switch self {
        case .failed(let message), .unauthorized(let message), .unsupported(let message): message
        }
    }
}

@MainActor
protocol SwitchService: AnyObject {
    var id: FeatureID { get }
    var onChange: (@MainActor () -> Void)? { get set }
    func read() async throws -> SwitchSnapshot
    func setEnabled(_ enabled: Bool) async throws -> SwitchSnapshot
    func shutdown()
}

extension SwitchService {
    func shutdown() {}
}
