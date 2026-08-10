import AVFoundation
import AppKit
import CoreVideo

/// Bakes a motion scene to an alpha ProRes 4444 .mov, mirroring `LottieVideoGenerator` so every
/// downstream consumer (composition, preview, export) sees an ordinary video.
enum MotionVideoGenerator {

    static let cache = DiskCache(named: "MotionVideos")
    static var cacheDirectory: URL { cache.directory }

    /// Final frame is held out to here so a clip can be extended past the animation (freeze-frame).
    private static let holdTailSeconds: Double = 1800

    @MainActor private static var inFlight: [String: Task<URL, any Error>] = [:]

    @concurrent
    static func loadScene(at url: URL) async throws -> MotionScene {
        try MotionScene.decoded(from: try Data(contentsOf: url))
    }

    static func cacheFilename(for scene: MotionScene) -> String {
        let target = scene.encodedSize
        return "\(scene.contentHash.prefix(32))_\(Int(target.width))x\(Int(target.height)).mov"
    }

    /// Pre-registers every unbaked scene a timeline needs, so the progress indicator
    /// knows the full queue and can estimate completion before the serial bakes start.
    @concurrent
    static func registerPendingBakes(
        timeline: Timeline,
        resolveURL: @Sendable (String) -> URL?,
        resolveTimeline: @Sendable (String) -> Timeline?
    ) async {
        var refs: Set<String> = []
        var visited: Set<String> = []
        collectMotionRefs(in: timeline, resolveTimeline: resolveTimeline, refs: &refs, visited: &visited)
        var pending: [(id: String, totalFrames: Int)] = []
        for ref in refs {
            guard let url = resolveURL(ref),
                  let data = try? Data(contentsOf: url),
                  let scene = try? MotionScene.decoded(from: data) else { continue }
            let filename = cacheFilename(for: scene)
            guard !FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent(filename).path) else { continue }
            pending.append((filename, scene.durationInFrames + 1))
        }
        let jobs = pending
        await MainActor.run { MotionBakeProgress.shared.setPending(jobs) }
    }

    private static func collectMotionRefs(
        in timeline: Timeline,
        resolveTimeline: @Sendable (String) -> Timeline?,
        refs: inout Set<String>,
        visited: inout Set<String>
    ) {
        for track in timeline.tracks where track.type == .video {
            for clip in track.clips {
                switch clip.mediaType {
                case .motion:
                    refs.insert(clip.mediaRef)
                case .sequence:
                    guard visited.insert(clip.mediaRef).inserted,
                          let child = resolveTimeline(clip.mediaRef) else { continue }
                    collectMotionRefs(in: child, resolveTimeline: resolveTimeline, refs: &refs, visited: &visited)
                default:
                    break
                }
            }
        }
    }

    /// The scene declares its own size and timing, so no caller-supplied size is accepted here.
    @MainActor
    static func motionVideo(for url: URL, mediaRef: String) async throws -> URL {
        let scene = try await loadScene(at: url)
        let target = scene.encodedSize
        let filename = cacheFilename(for: scene)
        let outputURL = cacheDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: outputURL.path) { return outputURL }

        if let existing = inFlight[filename] { return try await existing.value }
        let task = Task { @MainActor () throws -> URL in
            defer { inFlight[filename] = nil }
            MotionBakeProgress.shared.begin(id: filename, totalFrames: scene.durationInFrames + 1)
            defer { MotionBakeProgress.shared.end(id: filename) }
            do {
                try await render(scene: scene, target: target, to: outputURL, progressId: filename)
                return outputURL
            } catch {
                Log.preview.error("motionVideo failed mediaRef=\(mediaRef) size=\(Int(target.width))x\(Int(target.height)): \(Log.detail(error))")
                throw error
            }
        }
        inFlight[filename] = task
        return try await task.value
    }

    // MARK: - Private

    // ponytail: baking runs on the main actor because WKWebView cannot leave it, so a long scene
    // holds up the UI exactly like the Lottie path does. Move the web view into an XPC helper if
    // that ever becomes the bottleneck.
    @MainActor
    private static func render(scene: MotionScene, target: CGSize, to outputURL: URL, progressId: String) async throws {
        let renderer = try await MotionSceneRendererFactory.renderer(for: scene)
        defer { renderer.tearDown() }
        try await renderer.load(scene: scene)

        let fm = FileManager.default
        let parentDirectory = outputURL.deletingLastPathComponent()
        try? fm.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let tempURL = parentDirectory.appendingPathComponent(".writing-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: tempURL) }

        let writer = try AVAssetWriter(outputURL: tempURL, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: Int(target.width),
            AVVideoHeightKey: Int(target.height),
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(target.width),
                kCVPixelBufferHeightKey as String: Int(target.height),
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
        )
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? MotionSceneError.writeFailed }
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { throw MotionSceneError.writeFailed }

        var schedule = (0..<scene.durationInFrames).map { (frame: $0, seconds: Double($0) / scene.fps) }
        schedule.append((frame: scene.durationInFrames - 1, seconds: max(holdTailSeconds, scene.duration + 1)))

        var lastImage: CGImage?
        for (frame, seconds) in schedule {
            try Task.checkCancellation()
            let image: CGImage
            if let lastImage, frame == scene.durationInFrames - 1, seconds >= holdTailSeconds {
                image = lastImage
            } else {
                try await renderer.seek(toMilliseconds: Double(frame) / scene.fps * 1000)
                image = try await renderer.snapshot()
                lastImage = image
            }

            var bufferOut: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut) == kCVReturnSuccess,
                  let buffer = bufferOut else { throw MotionSceneError.pixelBufferCreationFailed }
            try draw(image, into: buffer, target: target)

            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard adaptor.append(buffer, withPresentationTime: CMTimeMakeWithSeconds(seconds, preferredTimescale: 600)) else {
                throw writer.error ?? MotionSceneError.appendFailed(frame: frame)
            }
            MotionBakeProgress.shared.advance(id: progressId)
        }

        // A scene that threw mid-animation would otherwise ship as a silently blank clip.
        try await renderer.assertSceneHealthy()

        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MotionSceneError.writeFailed }

        guard !fm.fileExists(atPath: outputURL.path) else { return }
        do {
            try fm.moveItem(at: tempURL, to: outputURL)
        } catch {
            guard fm.fileExists(atPath: outputURL.path) else { throw error }
        }
    }

    /// Snapshots come back at the display's backing scale, so the draw also does the downsample to
    /// the encoder's exact pixel size.
    private static func draw(_ image: CGImage, into buffer: CVPixelBuffer, target: CGSize) throws {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(target.width),
            height: Int(target.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw MotionSceneError.pixelBufferCreationFailed }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, colorSpace, .shouldPropagate)

        let rect = CGRect(origin: .zero, size: target)
        context.clear(rect)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
    }
}
