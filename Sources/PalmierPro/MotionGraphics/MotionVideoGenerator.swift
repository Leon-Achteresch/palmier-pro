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

    @MainActor private static var inFlight: [URL: Work] = [:]
    private static let renderGate = AsyncSemaphore(value: 1)

    @MainActor private final class Work {
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<URL, any Error>] = [:]
    }

    @concurrent
    static func loadScene(at url: URL) async throws -> MotionScene {
        try Task.checkCancellation()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= MotionScene.maxDocumentBytes else { throw MotionSceneError.invalidField("scene file is too large") }
        let scene = try MotionScene.decoded(from: Data(contentsOf: url))
        try Task.checkCancellation()
        return scene
    }

    static func cacheFilename(for scene: MotionScene) throws -> String {
        let target = scene.encodedSize
        return "\(try scene.contentHash.prefix(32))_\(Int(target.width))x\(Int(target.height)).mov"
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
            guard let filename = try? cacheFilename(for: scene) else { continue }
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

    @MainActor
    static func motionVideo(for url: URL, mediaRef: String, outputDirectory: URL? = nil) async throws -> URL {
        let prepared = try await prepare(url: url, outputDirectory: outputDirectory)
        try Task.checkCancellation()
        if prepared.cached { return prepared.output }
        let requestID = UUID()
        let output = prepared.output
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, any Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if let work = inFlight[output] { work.waiters[requestID] = continuation; return }
                let work = Work()
                work.waiters[requestID] = continuation
                inFlight[output] = work
                work.task = Task { @MainActor in
                    let result: Result<URL, any Error>
                    do {
                        try await renderGate.wait()
                        do {
                            try Task.checkCancellation()
                            MotionBakeProgress.shared.begin(id: output.lastPathComponent, totalFrames: prepared.scene.durationInFrames + 1)
                            defer { MotionBakeProgress.shared.end(id: output.lastPathComponent) }
                            try await render(scene: prepared.scene, target: prepared.scene.encodedSize, to: output, progressID: output.lastPathComponent)
                            await renderGate.signal()
                            result = .success(output)
                        } catch {
                            await renderGate.signal()
                            throw error
                        }
                    } catch {
                        if !(error is CancellationError) { Log.preview.error("motion bake failed mediaRef=\(mediaRef): \(Log.detail(error))") }
                        result = .failure(error)
                    }
                    guard inFlight[output] === work else { return }
                    inFlight.removeValue(forKey: output)
                    let waiting = work.waiters.values
                    work.waiters.removeAll()
                    for waiter in waiting { waiter.resume(with: result) }
                }
            }
        } onCancel: {
            Task { @MainActor in
                guard let work = inFlight[output], let waiter = work.waiters.removeValue(forKey: requestID) else { return }
                waiter.resume(throwing: CancellationError())
                if work.waiters.isEmpty { inFlight.removeValue(forKey: output); work.task?.cancel() }
            }
        }
        try Task.checkCancellation()
        return result
    }

    private struct Prepared: Sendable { var scene: MotionScene; var output: URL; var cached: Bool }

    @concurrent private static func prepare(url: URL, outputDirectory: URL?) async throws -> Prepared {
        let scene = try await loadScene(at: url)
        let output = (outputDirectory ?? cacheDirectory).appendingPathComponent(try cacheFilename(for: scene))
        return Prepared(scene: scene, output: output, cached: FileManager.default.fileExists(atPath: output.path))
    }

    @MainActor
    private static func render(scene: MotionScene, target: CGSize, to outputURL: URL, progressID: String) async throws {
        let renderer = try await MotionSceneRendererFactory.renderer(for: scene)
        defer { renderer.tearDown() }
        let encoder = MotionVideoEncoder(target: target, output: outputURL)
        do {
            try await renderer.load(scene: scene)
            try await encoder.start()
            let holdTime = CMTime(seconds: max(holdTailSeconds, scene.duration + 1), preferredTimescale: MotionScene.timeScale)
            var lastImage: CGImage?
            for frame in 0..<scene.durationInFrames {
                try Task.checkCancellation()
                try await renderer.seek(toMilliseconds: Double(frame) / scene.fps * 1000)
                let image = try await renderer.snapshot()
                lastImage = image
                try await encoder.append(image, at: scene.time(forFrame: frame), frame: frame)
                MotionBakeProgress.shared.advance(id: progressID)
            }
            if let lastImage {
                try await encoder.append(lastImage, at: holdTime, frame: scene.durationInFrames - 1)
                MotionBakeProgress.shared.advance(id: progressID)
            }
            try await renderer.assertSceneHealthy()
            try await encoder.finish(scene: scene, endTime: holdTime + scene.time(forFrame: 1))
        } catch {
            await encoder.cancel()
            throw error
        }
    }
}
