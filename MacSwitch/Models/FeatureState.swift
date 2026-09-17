import Foundation

enum OperationPhase: Equatable {
    case idle, working, succeeded
    case failed(String), unauthorized(String), unsupported(String)
    var message: String? {
        switch self {
        case .idle: nil
        case .working: "正在处理…"
        case .succeeded: "已更新"
        case .failed(let message), .unauthorized(let message), .unsupported(let message): message
        }
    }
    var isError: Bool {
        switch self {
        case .failed, .unauthorized, .unsupported: true
        default: false
        }
    }
}

struct FeatureState {
    var snapshot = SwitchSnapshot(isEnabled: false)
    var phase: OperationPhase = .idle
    var hasRead = false
    var isBusy: Bool { phase == .working }
    var isUnsupported: Bool {
        if case .unsupported = snapshot.availability { return true }
        return false
    }
}
