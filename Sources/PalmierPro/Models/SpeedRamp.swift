import Foundation

struct SpeedRamp: Sendable, Equatable {
    struct Segment: Sendable, Equatable {
        let clipFrame: Int
        let timelineFrames: Int
        let sourceOffset: Double
        let sourceFrames: Double

        var clipEndFrame: Int { clipFrame + timelineFrames }
        var sourceEndOffset: Double { sourceOffset + sourceFrames }
    }

    let durationFrames: Int
    let segments: [Segment]
    let sourceOffsetTotal: Double

    static let multiplierRange: ClosedRange<Double> = 0.1...10
    static let maxSegments = 64
    private static let curveSubdivisions = 8

    var sourceFramesConsumed: Int { Int(sourceOffsetTotal.rounded()) }

    func sourceOffset(atClipFrame frame: Int) -> Double {
        guard let first = segments.first, let last = segments.last else { return 0 }
        if frame <= first.clipFrame { return first.sourceOffset }
        if frame >= last.clipEndFrame { return last.sourceEndOffset }
        guard let segment = segments.last(where: { $0.clipFrame <= frame }) else { return first.sourceOffset }
        let t = Double(frame - segment.clipFrame) / Double(segment.timelineFrames)
        return segment.sourceOffset + segment.sourceFrames * t
    }

    func clipFrame(forSourceOffset offset: Double) -> Int? {
        guard let first = segments.first, let last = segments.last else { return nil }
        guard offset >= first.sourceOffset, offset <= last.sourceEndOffset else { return nil }
        guard let segment = segments.last(where: { $0.sourceOffset <= offset }) ?? segments.first else { return nil }
        guard segment.sourceFrames > 0 else { return segment.clipFrame }
        let t = (offset - segment.sourceOffset) / segment.sourceFrames
        return segment.clipFrame + Int((Double(segment.timelineFrames) * min(1, max(0, t))).rounded())
    }

    static func make(track: KeyframeTrack<Double>, durationFrames: Int, constantSpeed: Double) -> SpeedRamp? {
        guard durationFrames > 0, track.isActive else { return nil }
        let fallback = multiplierRange.contains(constantSpeed) ? constantSpeed : 1.0
        let keyframes = track.keyframes.sorted { $0.frame < $1.frame }
        let cuts = cutFrames(keyframes, durationFrames: durationFrames)
        guard cuts.count >= 2 else { return nil }

        func speed(at frame: Int) -> Double {
            let raw = track.sample(at: frame, fallback: fallback)
            guard raw.isFinite else { return fallback }
            return min(multiplierRange.upperBound, max(multiplierRange.lowerBound, raw))
        }

        var holdEnds = Set<Int>()
        for i in keyframes.indices.dropLast() where keyframes[i].interpolationOut == .hold {
            holdEnds.insert(keyframes[i + 1].frame)
        }

        var segments: [Segment] = []
        segments.reserveCapacity(cuts.count - 1)
        var offset = 0.0
        var next = speed(at: 0)
        var cutIndex = 1
        var segmentStartFrame = cuts[0]
        var segmentStartOffset = 0.0
        for frame in 0..<durationFrames {
            let current = next
            next = speed(at: frame + 1)
            offset += holdEnds.contains(frame + 1) ? current : (current + next) / 2
            if cutIndex < cuts.count, cuts[cutIndex] == frame + 1 {
                segments.append(Segment(
                    clipFrame: segmentStartFrame,
                    timelineFrames: frame + 1 - segmentStartFrame,
                    sourceOffset: segmentStartOffset,
                    sourceFrames: offset - segmentStartOffset
                ))
                segmentStartFrame = frame + 1
                segmentStartOffset = offset
                cutIndex += 1
            }
        }
        guard !segments.isEmpty else { return nil }
        return SpeedRamp(durationFrames: durationFrames, segments: segments, sourceOffsetTotal: offset)
    }

    private static func cutFrames(_ keyframes: [Keyframe<Double>], durationFrames: Int) -> [Int] {
        var candidates: Set<Int> = [0, durationFrames]
        for kf in keyframes where kf.frame > 0 && kf.frame < durationFrames {
            candidates.insert(kf.frame)
        }
        for i in keyframes.indices.dropLast() {
            let a = keyframes[i], b = keyframes[i + 1]
            guard a.interpolationOut != .hold, a.value != b.value else { continue }
            let lo = max(0, a.frame), hi = min(durationFrames, b.frame)
            guard hi > lo else { continue }
            candidates.formUnion(subdivisions(from: lo, to: hi))
        }
        return capped(candidates.sorted(), limit: maxSegments)
    }

    private static func subdivisions(from a: Int, to b: Int) -> [Int] {
        guard b > a else { return [] }
        let span = Double(b - a)
        return (1..<curveSubdivisions).map { a + Int((span * Double($0) / Double(curveSubdivisions)).rounded()) }
    }

    private static func capped(_ cuts: [Int], limit: Int) -> [Int] {
        guard cuts.count - 1 > limit else { return cuts }
        var kept: Set<Int> = [cuts[0], cuts[cuts.count - 1]]
        for i in 0...limit {
            let index = Int((Double(i) * Double(cuts.count - 1) / Double(limit)).rounded())
            kept.insert(cuts[min(index, cuts.count - 1)])
        }
        return kept.sorted()
    }
}

enum SpeedRampCache {
    private struct Key: Hashable {
        let track: KeyframeTrack<Double>
        let durationFrames: Int
        let constantSpeed: Double
    }

    private static let capacity = 64
    private static let lock = NSLock()
    nonisolated(unsafe) private static var entries: [Key: SpeedRamp] = [:]
    nonisolated(unsafe) private static var order: [Key] = []

    static func ramp(track: KeyframeTrack<Double>, durationFrames: Int, constantSpeed: Double) -> SpeedRamp? {
        let key = Key(track: track, durationFrames: durationFrames, constantSpeed: constantSpeed)
        lock.lock()
        let cached = entries[key]
        lock.unlock()
        if let cached { return cached }

        guard let built = SpeedRamp.make(
            track: track, durationFrames: durationFrames, constantSpeed: constantSpeed
        ) else { return nil }

        lock.lock()
        if entries[key] == nil {
            entries[key] = built
            order.append(key)
            while order.count > capacity {
                entries.removeValue(forKey: order.removeFirst())
            }
        }
        lock.unlock()
        return built
    }
}

enum SpeedRampRefusal: Error, Equatable, Sendable {
    case unsupportedMedia(clipId: String, mediaType: ClipType)
    case multicamMember(clipId: String)
    case emptyClip(clipId: String)
    case multiplierOutOfRange(clipId: String, frame: Int, multiplier: Double)
    case keyframeOutsideClip(clipId: String, frame: Int, durationFrames: Int)
    case insufficientSource(clipId: String, neededSourceFrames: Int, availableSourceFrames: Int)
    case transitionOnEdge(clipId: String, transitionId: String)

    var code: String {
        switch self {
        case .unsupportedMedia: "unsupported_media"
        case .multicamMember: "multicam_member"
        case .emptyClip: "empty_clip"
        case .multiplierOutOfRange: "multiplier_out_of_range"
        case .keyframeOutsideClip: "keyframe_outside_clip"
        case .insufficientSource: "insufficient_source"
        case .transitionOnEdge: "transition_on_edge"
        }
    }

    var missingSourceFrames: Int? {
        guard case .insufficientSource(_, let needed, let available) = self else { return nil }
        return needed - available
    }

    var message: String {
        switch self {
        case .unsupportedMedia(let id, let type):
            "Clip \(id) is '\(type.rawValue)' media; speed curves need video, audio, or motion media."
        case .multicamMember(let id):
            "Clip \(id) belongs to a multicam group; retiming would slip it out of sync."
        case .emptyClip(let id):
            "Clip \(id) has no duration to ramp across."
        case .multiplierOutOfRange(let id, let frame, let multiplier):
            "Clip \(id): speed \(multiplier) at frame \(frame) is out of range — use \(SpeedRamp.multiplierRange.lowerBound)…\(SpeedRamp.multiplierRange.upperBound)."
        case .keyframeOutsideClip(let id, let frame, let duration):
            "Clip \(id): speed keyframe at clip frame \(frame) falls outside the clip (0…\(duration))."
        case .insufficientSource(let id, let needed, let available):
            "Clip \(id) would consume \(needed) source frames but only \(available) are available — \(needed - available) frames short. Slow the curve down, shorten the clip, or expose more media."
        case .transitionOnEdge(let id, let transitionId):
            "Clip \(id) sits on transition \(transitionId); remove the transition before adding a speed curve."
        }
    }
}

extension Clip {
    var supportsSpeedRamp: Bool {
        supportsRetiming && hasBoundedSourceHandles
    }

    var speedRamp: SpeedRamp? {
        guard let track = speedTrack, track.isActive, durationFrames > 0 else { return nil }
        return SpeedRampCache.ramp(track: track, durationFrames: durationFrames, constantSpeed: speed)
    }

    var hasSpeedRamp: Bool { speedTrack?.isActive == true }

    func speedAt(frame: Int) -> Double {
        guard let track = speedTrack, track.isActive else { return speed }
        return track.sample(at: frame - startFrame, fallback: speed)
    }

    var constantSpeedSourceFrames: Int { Int((Double(durationFrames) * speed).rounded()) }

    var rampSourceBudgetFrames: Int {
        hasBoundedSourceHandles ? constantSpeedSourceFrames + max(0, trimEndFrame) : Int.max
    }

    var rampedSourceFramesConsumed: Int {
        speedRamp?.sourceFramesConsumed ?? constantSpeedSourceFrames
    }

    var speedRampFits: Bool {
        rampedSourceFramesConsumed <= rampSourceBudgetFrames
    }

    func validateSpeedRamp(_ track: KeyframeTrack<Double>?) throws(SpeedRampRefusal) {
        guard let track, track.isActive else { return }
        guard supportsSpeedRamp else {
            throw SpeedRampRefusal.unsupportedMedia(clipId: id, mediaType: mediaType)
        }
        guard multicamGroupId == nil else { throw SpeedRampRefusal.multicamMember(clipId: id) }
        guard durationFrames > 0 else { throw SpeedRampRefusal.emptyClip(clipId: id) }
        for kf in track.keyframes {
            guard kf.frame >= 0, kf.frame <= durationFrames else {
                throw SpeedRampRefusal.keyframeOutsideClip(clipId: id, frame: kf.frame, durationFrames: durationFrames)
            }
            guard kf.value.isFinite, SpeedRamp.multiplierRange.contains(kf.value) else {
                throw SpeedRampRefusal.multiplierOutOfRange(clipId: id, frame: kf.frame, multiplier: kf.value)
            }
        }
        guard let ramp = SpeedRampCache.ramp(
            track: track, durationFrames: durationFrames, constantSpeed: speed
        ) else { throw SpeedRampRefusal.emptyClip(clipId: id) }
        let budget = rampSourceBudgetFrames
        guard ramp.sourceFramesConsumed <= budget else {
            throw SpeedRampRefusal.insufficientSource(
                clipId: id, neededSourceFrames: ramp.sourceFramesConsumed, availableSourceFrames: budget
            )
        }
    }
}
