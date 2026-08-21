import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import PalmierPro

@Suite("Render cache — warm pass", .serialized)
struct RenderCacheWarmTests {

    static let renderSize = CompositorFixtures.renderSize
    static let warmedFrame = 15

    static func heavyTimeline(blurRadius: Double = 6) -> Timeline {
        var clip = CompositorFixtures.patternClip()
        clip.effects = [
            Effect(id: "blur", type: "blur.gaussian", params: ["radius": EffectParam(value: blurRadius)]),
            Effect(id: "sharp", type: "blur.sharpen", params: ["amount": EffectParam(value: 0.6)]),
        ]
        return CompositorFixtures.timeline([Fixtures.videoTrack(clips: [clip])])
    }

    static func build(_ timeline: Timeline) async throws -> CompositionResult {
        let url = try await CompositorFixtures.patternVideoURL()
        return try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { $0 == "pattern" ? url : nil },
            renderSize: renderSize
        )
    }

    static func plan(_ result: CompositionResult, fps: Int) async throws -> RenderWarmPlan {
        let tracks = try await result.composition.loadTracks(withMediaType: .video)
        return RenderWarmPlan(
            asset: result.composition,
            videoTracks: tracks,
            videoComposition: result.videoComposition,
            fps: fps,
            priorityFrame: warmedFrame
        )
    }

    static func renderedBytes(_ result: CompositionResult, frame: Int, fps: Int) async throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(
            at: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))
        ).image
        return ColorProbeHelpers.srgbBytes(image, size: renderSize)
    }

    static func temporaryStore() -> (store: RenderFrameStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-cache-warm-\(UUID().uuidString)", isDirectory: true)
        return (RenderFrameStore(cache: DiskCache(directory: directory), byteLimit: 1 << 24), directory)
    }

    @Test func cachedFramesMatchTheLiveRenderPixelForPixel() async throws {
        let timeline = Self.heavyTimeline()
        let result = try await Self.build(timeline)
        let (store, directory) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let live = try await Self.renderedBytes(result, frame: Self.warmedFrame, fps: timeline.fps)
        let span = try #require(
            RenderSpanWarmer.plannedSpans(in: result.videoComposition, priorityFrame: Self.warmedFrame).first
        )
        let key = RenderCacheKey(spanDigest: span.digest, frame: Self.warmedFrame)

        let outcome = await RenderSpanWarmer.warm(
            try await Self.plan(result, fps: timeline.fps),
            token: RenderPrefetchToken(),
            memory: .shared,
            store: store
        )
        #expect(outcome.renderedFrames > 0)
        #expect(RenderFrameCache.shared.contains(key))

        let served = try await Self.renderedBytes(result, frame: Self.warmedFrame, fps: timeline.fps)
        #expect(served == live)
    }

    @Test func theCompositorServesTheCachedFrameInsteadOfRendering() async throws {
        let timeline = Self.heavyTimeline(blurRadius: 11)
        let result = try await Self.build(timeline)
        let span = try #require(
            RenderSpanWarmer.plannedSpans(in: result.videoComposition, priorityFrame: Self.warmedFrame).first
        )
        let key = RenderCacheKey(spanDigest: span.digest, frame: Self.warmedFrame)
        RenderFrameCache.shared.store(Self.magentaBuffer(), for: key)
        defer { RenderFrameCache.shared.retain(digests: []) }

        let bytes = try await Self.renderedBytes(result, frame: Self.warmedFrame, fps: timeline.fps)
        let pixel = (r: Int(bytes[0]), g: Int(bytes[1]), b: Int(bytes[2]))
        #expect(pixel.r > 140 && pixel.g < 100 && pixel.b > 140, "expected the cached magenta frame, got \(pixel)")
    }

    static func magentaBuffer() -> CVPixelBuffer {
        let width = Int(renderSize.width), height = Int(renderSize.height)
        var pixels = Data(count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 255
            pixels[index + 1] = 0
            pixels[index + 2] = 255
            pixels[index + 3] = 255
        }
        let payload = RenderFramePayload(
            width: width, height: height, bytesPerRow: width * 4,
            pixels: pixels, attachments: Data()
        )
        let buffer = payload.makeBuffer()!
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return buffer
    }

    @Test func warmedFramesArePromotedFromDiskOnTheNextPass() async throws {
        let timeline = Self.heavyTimeline()
        let result = try await Self.build(timeline)
        let (store, directory) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = RenderFrameCache(byteLimit: 1 << 24)

        let first = await RenderSpanWarmer.warm(
            try await Self.plan(result, fps: timeline.fps),
            token: RenderPrefetchToken(), memory: memory, store: store
        )
        #expect(first.renderedFrames > 0)
        #expect(first.promotedFrames == 0)

        memory.removeAll()
        let second = await RenderSpanWarmer.warm(
            try await Self.plan(result, fps: timeline.fps),
            token: RenderPrefetchToken(), memory: memory, store: store
        )
        #expect(second.promotedFrames == first.renderedFrames)
        #expect(second.renderedFrames == 0)
    }

    @Test func aCancelledPassRendersNothing() async throws {
        let timeline = Self.heavyTimeline()
        let result = try await Self.build(timeline)
        let (store, directory) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = RenderFrameCache(byteLimit: 1 << 24)
        let token = RenderPrefetchToken()
        token.cancel()

        let outcome = await RenderSpanWarmer.warm(
            try await Self.plan(result, fps: timeline.fps),
            token: token, memory: memory, store: store
        )
        #expect(outcome.cancelled)
        #expect(outcome.warmedFrames == 0)
        #expect(memory.statistics.frames == 0)
        #expect(store.byteCount() == 0)
    }

    @Test func segmentsWithoutHeavyWorkAreNeverWarmed() async throws {
        let timeline = CompositorFixtures.timeline([
            Fixtures.videoTrack(clips: [CompositorFixtures.patternClip()])
        ])
        let result = try await Self.build(timeline)
        let (store, directory) = Self.temporaryStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = RenderFrameCache(byteLimit: 1 << 24)

        let outcome = await RenderSpanWarmer.warm(
            try await Self.plan(result, fps: timeline.fps),
            token: RenderPrefetchToken(), memory: memory, store: store
        )
        #expect(RenderSpanWarmer.plannedSpans(in: result.videoComposition, priorityFrame: 0).isEmpty)
        #expect(outcome.spans == 0)
        #expect(memory.statistics.frames == 0)
    }
}
