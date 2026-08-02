import Foundation

struct TimelineShotStats: Sendable {
    var pacing: PacingStats
    var longestSeconds: Double
    var longestClipId: String
}

struct BeatAlignment: Sendable, Equatable {
    var matchedFraction: Double
    var meanAbsOffsetFrames: Double
}

enum TimelineReview {
    static func primaryVideoTrackIndex(_ timeline: Timeline) -> Int? {
        var best: (index: Int, count: Int)?
        for (index, track) in timeline.tracks.enumerated() where track.type == .video {
            let count = track.clips.count(where: { $0.mediaType != .text })
            if count > 0, count > (best?.count ?? 0) {
                best = (index, count)
            }
        }
        return best?.index
    }

    static func shotStats(clips: [Clip], fps: Int, totalFrames: Int) -> TimelineShotStats? {
        guard fps > 0, totalFrames > 0 else { return nil }
        let sorted = clips.filter { $0.mediaType != .text }.sorted { $0.startFrame < $1.startFrame }
        guard !sorted.isEmpty else { return nil }
        let fpsD = Double(fps)
        let shots = sorted.map { clip in
            (midpoint: (Double(clip.startFrame) + Double(clip.durationFrames) / 2) / fpsD,
             seconds: Double(clip.durationFrames) / fpsD)
        }
        guard let pacing = ShotPacing.stats(shots: shots, duration: Double(totalFrames) / fpsD) else { return nil }
        var longest = (seconds: 0.0, clipId: sorted[0].id)
        for (clip, shot) in zip(sorted, shots) where shot.seconds > longest.seconds {
            longest = (shot.seconds, clip.id)
        }
        return TimelineShotStats(pacing: pacing, longestSeconds: longest.seconds, longestClipId: longest.clipId)
    }

    static func gaps(in clips: [Clip]) -> [(start: Int, end: Int)] {
        let sorted = clips.sorted { $0.startFrame < $1.startFrame }
        guard let first = sorted.first else { return [] }
        var result: [(start: Int, end: Int)] = []
        if first.startFrame > 0 {
            result.append((0, first.startFrame))
        }
        var coveredEnd = first.endFrame
        for clip in sorted.dropFirst() {
            if clip.startFrame > coveredEnd {
                result.append((coveredEnd, clip.startFrame))
            }
            coveredEnd = max(coveredEnd, clip.endFrame)
        }
        return result
    }

    static func cutFrames(_ clips: [Clip]) -> [Int] {
        clips.filter { $0.mediaType != .text }
            .sorted { $0.startFrame < $1.startFrame }
            .dropFirst()
            .map(\.startFrame)
    }

    static func beatAlignment(cutFrames: [Int], beatFrames: [Int], toleranceFrames: Int) -> BeatAlignment? {
        guard !cutFrames.isEmpty, !beatFrames.isEmpty else { return nil }
        let beats = beatFrames.sorted()
        var matched = 0
        var totalAbsOffset = 0.0
        for cut in cutFrames {
            var low = 0
            var high = beats.count
            while low < high {
                let mid = (low + high) / 2
                if beats[mid] < cut { low = mid + 1 } else { high = mid }
            }
            var nearest = Int.max
            if low < beats.count { nearest = abs(beats[low] - cut) }
            if low > 0 { nearest = min(nearest, abs(beats[low - 1] - cut)) }
            totalAbsOffset += Double(nearest)
            if nearest <= toleranceFrames { matched += 1 }
        }
        return BeatAlignment(
            matchedFraction: Double(matched) / Double(cutFrames.count),
            meanAbsOffsetFrames: totalAbsOffset / Double(cutFrames.count)
        )
    }

    static func findings(
        stats: TimelineShotStats?,
        gaps: [(start: Int, end: Int)],
        fps: Int,
        alignment: BeatAlignment?,
        beatCount: Int,
        toleranceFrames: Int,
        reference: ReferenceProfile?
    ) -> [String] {
        var findings: [String] = []
        let fpsD = Double(max(fps, 1))
        for gap in gaps.prefix(5) {
            let seconds = Double(gap.end - gap.start) / fpsD
            findings.append(String(
                format: "Primary video track renders black at frames %d–%d (%.1fs gap).",
                gap.start, gap.end, seconds
            ))
        }
        if gaps.count > 5 {
            findings.append("Primary video track has \(gaps.count - 5) more gaps.")
        }
        if let stats, stats.longestSeconds > max(6, 3 * stats.pacing.medianShotSeconds) {
            findings.append(String(
                format: "Longest shot (clip %@) runs %.1fs — %.1f× the median shot; check whether it holds attention.",
                stats.longestClipId, stats.longestSeconds,
                stats.longestSeconds / max(stats.pacing.medianShotSeconds, 0.1)
            ))
        }
        if let alignment, beatCount >= 8, alignment.matchedFraction < 0.3 {
            findings.append(String(
                format: "Only %.0f%% of cuts land within ±%d frames of a beat; consider aligning cuts to the music.",
                alignment.matchedFraction * 100, toleranceFrames
            ))
        }
        if let stats, let referencePacing = reference?.pacing {
            let ratio = stats.pacing.averageShotSeconds / max(referencePacing.averageShotSeconds, 0.1)
            if ratio > 1.5 {
                findings.append(String(
                    format: "Pacing is %.1f× slower than reference '%@' (%.1fs vs %.1fs average shot).",
                    ratio, reference?.name ?? "", stats.pacing.averageShotSeconds, referencePacing.averageShotSeconds
                ))
            } else if ratio < 1 / 1.5 {
                findings.append(String(
                    format: "Pacing is %.1f× faster than reference '%@' (%.1fs vs %.1fs average shot).",
                    1 / ratio, reference?.name ?? "", stats.pacing.averageShotSeconds, referencePacing.averageShotSeconds
                ))
            }
        }
        return findings
    }
}
