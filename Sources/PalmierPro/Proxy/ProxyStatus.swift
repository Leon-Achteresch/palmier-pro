import Foundation

enum ProxyStatus: Equatable, Sendable {
    case none
    case queued
    case generating
    case ready
    case failed(String)

    var serialized: String {
        switch self {
        case .none: "none"
        case .queued: "queued"
        case .generating: "generating"
        case .ready: "ready"
        case .failed(let message): "failed: \(message)"
        }
    }

    var manifestValue: String? {
        switch self {
        case .ready, .failed: serialized
        case .none, .queued, .generating: nil
        }
    }

    init(serialized value: String?) {
        switch value {
        case "ready": self = .ready
        case let value? where value.hasPrefix("failed: "):
            self = .failed(String(value.dropFirst("failed: ".count)))
        default: self = .none
        }
    }

    var isPending: Bool { self == .queued || self == .generating }

    var failureMessage: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}
