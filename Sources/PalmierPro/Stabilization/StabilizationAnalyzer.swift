import AVFoundation
import CoreGraphics
import Foundation
import Vision

struct StabilizationCacheKey: Hashable, Sendable {
    let mediaRef: String
    let assetTag: String
    let startSourceSeconds: Double
    let endSourceSeconds: Double
    let smoothing: Double

    static let formatVersion = 1

    var filename: String {
        let start = Int((startSourceSeconds * 1000).rounded())
        let end = Int((endSourceSeconds * 1000).rounded())
        let strength = Int((ClipStabilization.clampedSmoothing(smoothing) * 100).rounded())
        return "\(Self.sanitized(mediaRef))_\(assetTag)_\(start)-\(end)_s\(strength)_v\(Self.formatVersion).json"
    }

    var mediaPrefix: String { "\(Self.sanitized(mediaRef))_" }

    private static func sanitized(_ value: String) -> String {
        String(value.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }
}

enum StabilizationAnalyzer {
    static let cache = DiskCache(named: "Stabilization")
    static let maxAnalyzedSeconds: Double = 900
    static let analysisWidth = 480
    private static let progressStep = 0.02
    private static let gate = AsyncSemaphore(value: 1)

    enum AnalyzeError: LocalizedError, Equatable {
        case noVideoTrack
        case emptyRange
        case noFrames
        case mediaOffline
        case rangeTooLong(seconds: Double)
        case readFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: "The source has no video track to stabilize."
            case .emptyRange: "The clip's source range is empty."
            case .mediaOffline: "The clip's media is offline. Relink it, then stabilize again."
            case .noFrames: "No frames could be decoded from the clip's source range."
            case .rangeTooLong(let seconds):
                "The clip spans \(Int(seconds.rounded())) s of source; stabilization analyzes at most \(Int(maxAnalyzedSeconds)) s."
            case .readFailed(let reason): "Could not read the source: \(reason)"
            }
        }
    }

    struct Request: Sendable, Equatable {
        let url: URL
        let mediaRef: String
        let assetTag: String
        let startSourceSeconds: Double
        let endSourceSeconds: Double
        let smoothing: Double

        var key: StabilizationCacheKey {
            StabilizationCacheKey(
                mediaRef: mediaRef,
                assetTag: assetTag,
                startSourceSeconds: startSourceSeconds,
                endSourceSeconds: endSourceSeconds,
                smoothing: smoothing
            )
        }
    }

    @concurrent
    static func request(for clip: Clip, resolver: MediaResolver, fps: Int) async throws -> Request {
        guard let url = resolver.resolveURL(for: clip.mediaRef) else { throw AnalyzeError.mediaOffline }
        guard let range = clip.sourceSecondsRange(fps: fps) else { throw AnalyzeError.emptyRange }
        return Request(
            url: url,
            mediaRef: clip.mediaRef,
            assetTag: DiskCache.sizeMtimeTag(for: url),
            startSourceSeconds: range.lowerBound,
            endSourceSeconds: range.upperBound,
            smoothing: ClipStabilization.clampedSmoothing(clip.stabilization?.smoothing ?? ClipStabilization.defaultSmoothing)
        )
    }

    @concurrent
    static func analyze(
        _ request: Request,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ClipStabilization {
        if let cached = cached(request) { return cached }
        try await gate.wait()
        defer { Task { await gate.signal() } }
        try Task.checkCancellation()
        if let cached = cached(request) { return cached }

        let started = ContinuousClock.now
        let measured = try await motions(request, progress: progress)
        try Task.checkCancellation()
        let plan = StabilizationTrajectory.plan(
            motions: measured.motions,
            smoothing: request.smoothing,
            aspect: measured.aspect
        )
        let result = ClipStabilization(
            smoothing: ClipStabilization.clampedSmoothing(request.smoothing),
            startSourceSeconds: request.startSourceSeconds,
            endSourceSeconds: request.endSourceSeconds,
            sampleRate: measured.sampleRate,
            cropScale: plan.cropScale,
            samples: plan.samples
        )
        store(result, for: request.key)
        let elapsed = Double(started.duration(to: .now).components.seconds)
        Log.preview.notice("""
            stabilize ok mediaRef=\(request.mediaRef) frames=\(plan.samples.count) \
            crop=\(String(format: "%.1f", result.cropPercent))% seconds=\(String(format: "%.0f", elapsed))
            """)
        return result
    }

    static func cached(_ request: Request) -> ClipStabilization? {
        let url = cache.directory.appendingPathComponent(request.key.filename)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ClipStabilization.self, from: data),
              decoded.isAnalyzed else { return nil }
        return decoded
    }

    private static func store(_ result: ClipStabilization, for key: StabilizationCacheKey) {
        guard let data = try? JSONEncoder().encode(result) else { return }
        removeStaleCaches(for: key)
        let destination = cache.directory.appendingPathComponent(key.filename)
        guard let staged = try? FileIO.stageData(data, pathExtension: "json") else { return }
        do {
            try FileIO.moveReplacingDestination(from: staged, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            Log.preview.warning("stabilize cache write failed: \(error.localizedDescription)")
        }
    }

    private static func removeStaleCaches(for key: StabilizationCacheKey) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(key.mediaPrefix)
            && !entry.lastPathComponent.contains(key.assetTag) {
            try? fm.removeItem(at: entry)
        }
    }

    private struct Measurement {
        let motions: [StabilizationSample]
        let sampleRate: Double
        let aspect: Double
    }

    private static func motions(
        _ request: Request,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Measurement {
        let span = request.endSourceSeconds - request.startSourceSeconds
        guard span > 0, span.isFinite else { throw AnalyzeError.emptyRange }
        guard span <= maxAnalyzedSeconds else { throw AnalyzeError.rangeTooLong(seconds: span) }

        let asset = AVURLAsset(url: request.url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AnalyzeError.noVideoTrack
        }
        let naturalSize = try await track.load(.naturalSize)
        let width = abs(naturalSize.width), height = abs(naturalSize.height)
        guard width >= 1, height >= 1 else { throw AnalyzeError.noVideoTrack }
        let nominalRate = Double(try await track.load(.nominalFrameRate))
        let sampleRate = nominalRate.isFinite && nominalRate > 0 ? nominalRate : 30

        let scaled = analysisSize(width: width, height: height)
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: request.startSourceSeconds, preferredTimescale: 600),
            end: CMTime(seconds: request.endSourceSeconds, preferredTimescale: 600)
        )
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(scaled.width),
            kCVPixelBufferHeightKey as String: Int(scaled.height),
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AnalyzeError.readFailed("output rejected") }
        reader.add(output)
        guard reader.startReading() else {
            throw AnalyzeError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }

        let capacity = Int((span * sampleRate).rounded(.up)) + 1
        var motions = [StabilizationSample](repeating: .identity, count: max(1, capacity))
        var previous: CVPixelBuffer?
        var decoded = 0
        var lastReported = 0.0
        var draining = true

        while draining {
            try autoreleasepool {
                if Task.isCancelled {
                    reader.cancelReading()
                    throw CancellationError()
                }
                guard let sample = output.copyNextSampleBuffer() else {
                    draining = false
                    return
                }
                defer { previous = CMSampleBufferGetImageBuffer(sample) }
                guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
                let presentation = CMSampleBufferGetPresentationTimeStamp(sample)
                guard presentation.isNumeric else { return }
                decoded += 1
                guard let previous else { return }
                let motion = interframeMotion(from: previous, to: buffer, size: scaled)
                let offset = (presentation.seconds - request.startSourceSeconds) * sampleRate
                guard offset.isFinite else { return }
                let index = min(max(Int(offset.rounded()), 0), motions.count - 1)
                motions[index].dx += motion.dx
                motions[index].dy += motion.dy
                motions[index].rotation += motion.rotation
                let fraction = min(1, max(0, (presentation.seconds - request.startSourceSeconds) / span))
                if fraction - lastReported >= progressStep {
                    lastReported = fraction
                    progress(fraction)
                }
            }
        }

        if reader.status == .failed {
            throw AnalyzeError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }
        guard decoded > 0 else { throw AnalyzeError.noFrames }
        progress(1)
        return Measurement(motions: motions, sampleRate: sampleRate, aspect: width / height)
    }

    private static func analysisSize(width: CGFloat, height: CGFloat) -> CGSize {
        guard width > CGFloat(analysisWidth) else {
            return CGSize(width: max(1, width.rounded()), height: max(1, height.rounded()))
        }
        let scale = CGFloat(analysisWidth) / width
        return CGSize(width: CGFloat(analysisWidth), height: max(1, (height * scale).rounded()))
    }

    private static func interframeMotion(
        from previous: CVPixelBuffer,
        to current: CVPixelBuffer,
        size: CGSize
    ) -> StabilizationSample {
        var motion = StabilizationSample.identity
        let translation = VNTranslationalImageRegistrationRequest(targetedCVPixelBuffer: current)
        try? VNImageRequestHandler(cvPixelBuffer: previous).perform([translation])
        guard let aligned = translation.results?.first as? VNImageTranslationAlignmentObservation else {
            return motion
        }
        let transform = aligned.alignmentTransform
        guard transform.tx.isFinite, transform.ty.isFinite else { return motion }
        motion.dx = -Double(transform.tx) / Double(size.width)
        motion.dy = -Double(transform.ty) / Double(size.height)
        guard abs(motion.dx) <= 1, abs(motion.dy) <= 1 else { return .identity }

        let homography = VNHomographicImageRegistrationRequest(targetedCVPixelBuffer: current)
        try? VNImageRequestHandler(cvPixelBuffer: previous).perform([homography])
        if let warp = (homography.results?.first as? VNImageHomographicAlignmentObservation)?.warpTransform {
            motion.rotation = roll(from: warp)
        }
        return motion
    }

    private static let maxRoll = 5 * Double.pi / 180

    private static func roll(from warp: simd_float3x3) -> Double {
        let m00 = Double(warp.columns.0.x), m10 = Double(warp.columns.0.y)
        let m01 = Double(warp.columns.1.x), m11 = Double(warp.columns.1.y)
        let scaleX = (m00 * m00 + m10 * m10).squareRoot()
        let scaleY = (m01 * m01 + m11 * m11).squareRoot()
        guard scaleX.isFinite, scaleY.isFinite, abs(scaleX - 1) < 0.2, abs(scaleY - 1) < 0.2 else { return 0 }
        let angle = -atan2(m10, m00)
        guard angle.isFinite, abs(angle) <= maxRoll else { return 0 }
        return angle
    }
}
