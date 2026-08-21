import Foundation

enum MixPlatformPreset: String, CaseIterable, Sendable {
    case youtube
    case podcast
    case film

    var programLufs: Double {
        switch self {
        case .youtube: -14
        case .podcast: -16
        case .film: -23
        }
    }

    var dialogLufs: Double {
        switch self {
        case .youtube: -16
        case .podcast: -18
        case .film: -25
        }
    }

    var truePeakCeilingDbtp: Double {
        switch self {
        case .youtube, .podcast: -1
        case .film: -2
        }
    }

    static let bedOffsetDb: Double = -12
    static let sfxOffsetDb: Double = -4

    func targetLufs(for role: AudioClipRole) -> Double? {
        switch role {
        case .dialog: dialogLufs
        case .bed: dialogLufs + Self.bedOffsetDb
        case .sfx: dialogLufs + Self.sfxOffsetDb
        case .exempt: nil
        }
    }
}
