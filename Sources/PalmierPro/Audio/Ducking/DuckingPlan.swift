import Foundation

struct DuckInterval: Sendable, Equatable {
    let attackStart: Int
    let fullStart: Int
    let fullEnd: Int
    let releaseEnd: Int
}

struct DuckingCurve: Sendable, Equatable {
    let intervals: [DuckInterval]
    let depthGain: Double

    func gain(atFrame frame: Int) -> Double {
        guard let interval = interval(covering: frame) else { return 1 }
        if frame >= interval.fullStart && frame <= interval.fullEnd { return depthGain }
        if frame < interval.fullStart {
            let span = interval.fullStart - interval.attackStart
            guard span > 0 else { return depthGain }
            return 1 + (depthGain - 1) * Double(frame - interval.attackStart) / Double(span)
        }
        let span = interval.releaseEnd - interval.fullEnd
        guard span > 0 else { return 1 }
        return depthGain + (1 - depthGain) * Double(frame - interval.fullEnd) / Double(span)
    }

    private func interval(covering frame: Int) -> DuckInterval? {
        var low = 0
        var high = intervals.count
        while low < high {
            let mid = (low + high) / 2
            if intervals[mid].releaseEnd <= frame { low = mid + 1 } else { high = mid }
        }
        guard low < intervals.count else { return nil }
        let candidate = intervals[low]
        return frame > candidate.attackStart ? candidate : nil
    }

    var breakpointFrames: [Int] {
        intervals.flatMap { [$0.attackStart, $0.fullStart, $0.fullEnd, $0.releaseEnd] }
    }
}

struct DuckingPlan: Sendable, Equatable {
    let curvesByClipId: [String: DuckingCurve]

    static let empty = DuckingPlan(curvesByClipId: [:])

    var isEmpty: Bool { curvesByClipId.isEmpty }

    func curve(forClipId id: String) -> DuckingCurve? { curvesByClipId[id] }
}

extension DuckingPlan {
    static func mergedSpeech(_ spans: [FrameRange], bridgeFrames: Int) -> [FrameRange] {
        let sorted = spans.filter { $0.length > 0 }.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        guard var current = sorted.first else { return [] }
        var out: [FrameRange] = []
        for span in sorted.dropFirst() {
            if span.start - current.end <= bridgeFrames {
                current = FrameRange(start: current.start, end: max(current.end, span.end))
            } else {
                out.append(current)
                current = span
            }
        }
        out.append(current)
        return out
    }

    static func intervals(
        forSpeech speech: [FrameRange],
        clipRange: FrameRange,
        attackFrames: Int,
        releaseFrames: Int
    ) -> [DuckInterval] {
        guard clipRange.length > 0 else { return [] }
        var out: [DuckInterval] = []
        for span in speech {
            let fullStart = max(span.start, clipRange.start)
            let fullEnd = min(span.end, clipRange.end)
            guard fullEnd > fullStart else { continue }
            let attackStart = max(clipRange.start, fullStart - max(0, attackFrames))
            let releaseEnd = min(clipRange.end, fullEnd + max(0, releaseFrames))
            let interval = DuckInterval(
                attackStart: attackStart, fullStart: fullStart, fullEnd: fullEnd, releaseEnd: releaseEnd
            )
            guard let previous = out.last, interval.attackStart <= previous.releaseEnd else {
                out.append(interval)
                continue
            }
            out[out.count - 1] = DuckInterval(
                attackStart: previous.attackStart,
                fullStart: previous.fullStart,
                fullEnd: max(previous.fullEnd, interval.fullEnd),
                releaseEnd: max(previous.releaseEnd, interval.releaseEnd)
            )
        }
        return out
    }
}
