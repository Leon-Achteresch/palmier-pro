import Foundation

enum DuckingRole: String, Codable, Sendable, CaseIterable, Equatable {
    case auto
    case dialog
    case bed
    case exempt
}

enum DuckingLimits {
    static let depthDb: ClosedRange<Double> = -60...0
    static let attackMs: ClosedRange<Double> = 0...2000
    static let releaseMs: ClosedRange<Double> = 0...5000
    static let holdMs: ClosedRange<Double> = 0...5000

    static let depthDbDefault: Double = -12
    static let attackMsDefault: Double = 150
    static let releaseMsDefault: Double = 400
    static let holdMsDefault: Double = 600

    static let dialogSpeechCoverage: Double = 0.3
}

struct TimelineDuckingSettings: Codable, Sendable, Equatable {
    var enabled: Bool = false
    var depthDb: Double = DuckingLimits.depthDbDefault
    var attackMs: Double = DuckingLimits.attackMsDefault
    var releaseMs: Double = DuckingLimits.releaseMsDefault
    var holdMs: Double = DuckingLimits.holdMsDefault

    private enum CodingKeys: String, CodingKey {
        case enabled, depthDb, attackMs, releaseMs, holdMs
    }

    init(
        enabled: Bool = false,
        depthDb: Double = DuckingLimits.depthDbDefault,
        attackMs: Double = DuckingLimits.attackMsDefault,
        releaseMs: Double = DuckingLimits.releaseMsDefault,
        holdMs: Double = DuckingLimits.holdMsDefault
    ) {
        self.enabled = enabled
        self.depthDb = depthDb
        self.attackMs = attackMs
        self.releaseMs = releaseMs
        self.holdMs = holdMs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? false,
            depthDb: (try? c.decode(Double.self, forKey: .depthDb)) ?? DuckingLimits.depthDbDefault,
            attackMs: (try? c.decode(Double.self, forKey: .attackMs)) ?? DuckingLimits.attackMsDefault,
            releaseMs: (try? c.decode(Double.self, forKey: .releaseMs)) ?? DuckingLimits.releaseMsDefault,
            holdMs: (try? c.decode(Double.self, forKey: .holdMs)) ?? DuckingLimits.holdMsDefault
        )
        self = normalized
    }

    var normalized: TimelineDuckingSettings {
        var out = self
        out.depthDb = Self.clamped(depthDb, to: DuckingLimits.depthDb, fallback: DuckingLimits.depthDbDefault)
        out.attackMs = Self.clamped(attackMs, to: DuckingLimits.attackMs, fallback: DuckingLimits.attackMsDefault)
        out.releaseMs = Self.clamped(releaseMs, to: DuckingLimits.releaseMs, fallback: DuckingLimits.releaseMsDefault)
        out.holdMs = Self.clamped(holdMs, to: DuckingLimits.holdMs, fallback: DuckingLimits.holdMsDefault)
        return out
    }

    var depthGain: Double { VolumeScale.linearFromDb(depthDb) }

    func frames(forMilliseconds ms: Double, fps: Int) -> Int {
        guard fps > 0, ms.isFinite, ms > 0 else { return 0 }
        return max(0, Int((ms / 1000 * Double(fps)).rounded()))
    }

    private static func clamped(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, value))
    }
}
