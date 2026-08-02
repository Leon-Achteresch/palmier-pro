import Foundation

struct ReferenceProfile: Codable, Sendable, Identifiable {
    let id: String
    var name: String
    var sourceFileName: String
    var createdDate: Date
    var durationSeconds: Double
    var pacing: PacingStats?
    var bpm: Double?
    var audio: AudioStats?
    var look: LookStats?
}

struct PacingStats: Codable, Sendable, Equatable {
    var shotCount: Int
    var averageShotSeconds: Double
    var medianShotSeconds: Double
    var sectionAverageShotSeconds: [Double]
}

struct AudioStats: Codable, Sendable, Equatable {
    var energyMean: Double
    var quietFraction: Double
}

struct LookStats: Codable, Sendable, Equatable {
    var lumaMean: Double
    var saturationMean: Double
    var warmCoolBias: Double
    var hueHistogram: [Double]
}

enum ShotPacing {
    static func stats(shots: [(midpoint: Double, seconds: Double)], duration: Double) -> PacingStats? {
        guard !shots.isEmpty, duration > 0 else { return nil }
        let lengths = shots.map(\.seconds)
        let sorted = lengths.sorted()
        var sections: [[Double]] = [[], [], []]
        for shot in shots {
            let index = min(2, max(0, Int(shot.midpoint * 3 / duration)))
            sections[index].append(shot.seconds)
        }
        return PacingStats(
            shotCount: shots.count,
            averageShotSeconds: lengths.reduce(0, +) / Double(lengths.count),
            medianShotSeconds: sorted[sorted.count / 2],
            sectionAverageShotSeconds: sections.map { $0.isEmpty ? 0 : $0.reduce(0, +) / Double($0.count) }
        )
    }
}
