import Foundation

enum AwakeDuration: String, CaseIterable, Codable, Identifiable, Sendable {
    case thirtyMinutes, oneHour, untilDisabled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .thirtyMinutes: "30 分钟"
        case .oneHour: "1 小时"
        case .untilDisabled: "直到关闭"
        }
    }
    var seconds: TimeInterval? {
        switch self {
        case .thirtyMinutes: 1800
        case .oneHour: 3600
        case .untilDisabled: nil
        }
    }
}
