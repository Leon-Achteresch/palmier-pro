import Foundation

struct StabilizationSample: Sendable, Equatable {
    var dx: Double
    var dy: Double
    var rotation: Double

    static let identity = StabilizationSample(dx: 0, dy: 0, rotation: 0)

    var isIdentity: Bool { dx == 0 && dy == 0 && rotation == 0 }
}

struct ClipStabilization: Codable, Sendable, Equatable {
    var smoothing: Double
    var startSourceSeconds: Double
    var endSourceSeconds: Double
    var sampleRate: Double
    var cropScale: Double
    var samples: [StabilizationSample]

    static let smoothingRange: ClosedRange<Double> = 0...1
    static let defaultSmoothing: Double = 0.5
    static let maxCropScale: Double = 1.35
    static let coverageToleranceSeconds: Double = 0.25

    init(
        smoothing: Double,
        startSourceSeconds: Double = 0,
        endSourceSeconds: Double = 0,
        sampleRate: Double = 0,
        cropScale: Double = 1,
        samples: [StabilizationSample] = []
    ) {
        self.smoothing = smoothing
        self.startSourceSeconds = startSourceSeconds
        self.endSourceSeconds = endSourceSeconds
        self.sampleRate = sampleRate
        self.cropScale = cropScale
        self.samples = samples
    }

    static func requested(smoothing: Double) -> ClipStabilization {
        ClipStabilization(smoothing: clampedSmoothing(smoothing))
    }

    static func clampedSmoothing(_ value: Double) -> Double {
        guard value.isFinite else { return defaultSmoothing }
        return min(smoothingRange.upperBound, max(smoothingRange.lowerBound, value))
    }

    var isAnalyzed: Bool { !samples.isEmpty && sampleRate > 0 }

    var cropPercent: Double { cropScale > 1 ? (1 - 1 / cropScale) * 100 : 0 }

    var analyzedSeconds: Double { max(0, endSourceSeconds - startSourceSeconds) }

    func sample(atSourceSeconds seconds: Double) -> StabilizationSample? {
        guard isAnalyzed, seconds.isFinite else { return nil }
        let position = (seconds - startSourceSeconds) * sampleRate
        guard position.isFinite else { return nil }
        let index = Int(min(max(position.rounded(), 0), Double(samples.count - 1)))
        return samples[index]
    }

    func covers(sourceSeconds range: ClosedRange<Double>) -> Bool {
        guard isAnalyzed else { return false }
        return range.lowerBound >= startSourceSeconds - Self.coverageToleranceSeconds
            && range.upperBound <= endSourceSeconds + Self.coverageToleranceSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case smoothing, startSourceSeconds, endSourceSeconds, sampleRate, cropScale, samples
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func finite(_ key: CodingKeys, fallback: Double) -> Double {
            let value = (try? c.decode(Double.self, forKey: key)) ?? fallback
            return value.isFinite ? value : fallback
        }
        self.init(
            smoothing: Self.clampedSmoothing(finite(.smoothing, fallback: Self.defaultSmoothing)),
            startSourceSeconds: max(0, finite(.startSourceSeconds, fallback: 0)),
            endSourceSeconds: max(0, finite(.endSourceSeconds, fallback: 0)),
            sampleRate: max(0, finite(.sampleRate, fallback: 0)),
            cropScale: max(1, finite(.cropScale, fallback: 1)),
            samples: Self.unpacked((try? c.decode(Data.self, forKey: .samples)) ?? Data())
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(smoothing, forKey: .smoothing)
        try c.encode(startSourceSeconds, forKey: .startSourceSeconds)
        try c.encode(endSourceSeconds, forKey: .endSourceSeconds)
        try c.encode(sampleRate, forKey: .sampleRate)
        try c.encode(cropScale, forKey: .cropScale)
        if !samples.isEmpty { try c.encode(Self.packed(samples), forKey: .samples) }
    }

    static func packed(_ samples: [StabilizationSample]) -> Data {
        var floats: [Float] = []
        floats.reserveCapacity(samples.count * 3)
        for sample in samples {
            floats.append(Float(sample.dx))
            floats.append(Float(sample.dy))
            floats.append(Float(sample.rotation))
        }
        return floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func unpacked(_ data: Data) -> [StabilizationSample] {
        let stride = 3 * MemoryLayout<Float>.size
        let count = data.count / stride
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw -> [StabilizationSample] in
            (0..<count).map { index in
                func value(_ slot: Int) -> Double {
                    let float = raw.loadUnaligned(
                        fromByteOffset: index * stride + slot * MemoryLayout<Float>.size,
                        as: Float.self
                    )
                    return float.isFinite ? Double(float) : 0
                }
                return StabilizationSample(dx: value(0), dy: value(1), rotation: value(2))
            }
        }
    }
}

enum StabilizationRefusal: Error, Equatable, Sendable {
    case unsupportedMedia(clipId: String, mediaType: ClipType)
    case multicamMember(clipId: String)
    case emptyClip(clipId: String)
    case smoothingOutOfRange(clipId: String, smoothing: Double)
    case sourceTooLong(clipId: String, seconds: Double, limitSeconds: Double)

    var code: String {
        switch self {
        case .unsupportedMedia: "unsupported_media"
        case .multicamMember: "multicam_member"
        case .emptyClip: "empty_clip"
        case .smoothingOutOfRange: "smoothing_out_of_range"
        case .sourceTooLong: "source_too_long"
        }
    }

    var message: String {
        switch self {
        case .unsupportedMedia(let id, let type):
            "Clip \(id) is '\(type.rawValue)' media; stabilization needs a video clip."
        case .multicamMember(let id):
            "Clip \(id) belongs to a multicam group; stabilize the angle's source clip instead."
        case .emptyClip(let id):
            "Clip \(id) has no duration to analyze."
        case .smoothingOutOfRange(let id, let smoothing):
            "Clip \(id): smoothing \(smoothing) is out of range — use \(ClipStabilization.smoothingRange.lowerBound)…\(ClipStabilization.smoothingRange.upperBound)."
        case .sourceTooLong(let id, let seconds, let limit):
            "Clip \(id) spans \(Int(seconds.rounded())) s of source; stabilization analyzes at most \(Int(limit)) s. Split the clip first."
        }
    }
}

extension Clip {
    var supportsStabilization: Bool {
        mediaType == .video && sourceClipType != .sequence && multicamGroupId == nil
    }

    var isStabilized: Bool { stabilization != nil }

    func sourceSeconds(atTimelineFrame frame: Int, fps: Int) -> Double? {
        guard fps > 0, durationFrames > 0 else { return nil }
        let clipFrame = min(max(frame - startFrame, 0), durationFrames)
        let offset = speedRamp?.sourceOffset(atClipFrame: clipFrame) ?? Double(clipFrame) * speed
        guard offset.isFinite else { return nil }
        return (Double(trimStartFrame) + offset) / Double(fps)
    }

    func sourceSecondsRange(fps: Int) -> ClosedRange<Double>? {
        guard fps > 0, durationFrames > 0 else { return nil }
        let start = Double(trimStartFrame) / Double(fps)
        let end = Double(trimStartFrame + max(1, rampedSourceFramesConsumed)) / Double(fps)
        guard start.isFinite, end.isFinite, end > start else { return nil }
        return start...end
    }

    func stabilizationSample(atTimelineFrame frame: Int, fps: Int) -> StabilizationSample? {
        guard let stabilization, stabilization.isAnalyzed,
              let seconds = sourceSeconds(atTimelineFrame: frame, fps: fps) else { return nil }
        return stabilization.sample(atSourceSeconds: seconds)
    }

    func stabilizationIsStale(fps: Int) -> Bool {
        guard let stabilization, stabilization.isAnalyzed,
              let range = sourceSecondsRange(fps: fps) else { return false }
        return !stabilization.covers(sourceSeconds: range)
    }

    func stabilizationSignature(fps: Int) -> String {
        let smoothing = ClipStabilization.clampedSmoothing(
            stabilization?.smoothing ?? ClipStabilization.defaultSmoothing
        )
        let range = sourceSecondsRange(fps: fps)
        let start = Int(((range?.lowerBound ?? 0) * 1000).rounded())
        let end = Int(((range?.upperBound ?? 0) * 1000).rounded())
        return "\(mediaRef)|\(Int((smoothing * 100).rounded()))|\(start)|\(end)"
    }

    func stabilizationMatches(smoothing: Double, fps: Int) -> Bool {
        guard let stabilization else { return false }
        let requested = ClipStabilization.clampedSmoothing(smoothing)
        return abs(stabilization.smoothing - requested) < 0.005 && !stabilizationIsStale(fps: fps)
    }

    func validateStabilization(smoothing: Double, fps: Int) throws(StabilizationRefusal) {
        guard smoothing.isFinite, ClipStabilization.smoothingRange.contains(smoothing) else {
            throw StabilizationRefusal.smoothingOutOfRange(clipId: id, smoothing: smoothing)
        }
        guard multicamGroupId == nil else { throw StabilizationRefusal.multicamMember(clipId: id) }
        guard supportsStabilization else {
            throw StabilizationRefusal.unsupportedMedia(clipId: id, mediaType: mediaType)
        }
        guard durationFrames > 0, let range = sourceSecondsRange(fps: fps) else {
            throw StabilizationRefusal.emptyClip(clipId: id)
        }
        let span = range.upperBound - range.lowerBound
        guard span <= StabilizationAnalyzer.maxAnalyzedSeconds else {
            throw StabilizationRefusal.sourceTooLong(
                clipId: id, seconds: span, limitSeconds: StabilizationAnalyzer.maxAnalyzedSeconds
            )
        }
    }
}
