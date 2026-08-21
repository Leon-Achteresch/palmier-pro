import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import PalmierPro

@Suite("Render cache — keys and invalidation")
struct RenderCacheDigestTests {

    static func heavyClip(id: String = "c1", start: Int = 0, duration: Int = 30) -> Clip {
        var clip = Fixtures.clip(id: id, mediaType: .text, start: start, duration: duration)
        clip.textContent = "Title"
        clip.effects = [
            Effect(id: "e1", type: "blur.gaussian", params: ["radius": EffectParam(value: 8)]),
            Effect(id: "e2", type: "stylize.glow", params: ["intensity": EffectParam(value: 0.5)]),
            Effect(id: "e3", type: "color.curves", params: ["amount": EffectParam(value: 0.2)]),
        ]
        return clip
    }

    static func instruction(
        _ clips: [Clip],
        frames: Range<Int> = 0..<30,
        fps: Int = 30,
        renderSize: CGSize = CGSize(width: 320, height: 180)
    ) -> CompositorInstruction {
        let layers = clips.map {
            LayerPlan(source: .text, clip: $0, natSize: renderSize, preferredTransform: .identity)
        }
        let timescale = CMTimeScale(fps)
        return CompositorInstruction(
            timeRange: CMTimeRange(
                start: CMTime(value: CMTimeValue(frames.lowerBound), timescale: timescale),
                end: CMTime(value: CMTimeValue(frames.upperBound), timescale: timescale)
            ),
            layers: layers,
            renderSize: renderSize,
            fps: fps
        )
    }

    @Test func cheapSegmentsAreNotCached() {
        var plain = Fixtures.clip(id: "c1", mediaType: .text, start: 0, duration: 30)
        plain.textContent = "Title"
        #expect(Self.instruction([plain]).renderCacheSpan == nil)
    }

    @Test func effectHeavySegmentReportsItsFrameRange() throws {
        let span = try #require(Self.instruction([Self.heavyClip()], frames: 12..<42).renderCacheSpan)
        #expect(span.frames == 12..<42)
    }

    @Test func identicalSegmentsShareOneDigest() throws {
        let first = try #require(Self.instruction([Self.heavyClip()]).renderCacheSpan)
        let second = try #require(Self.instruction([Self.heavyClip()]).renderCacheSpan)
        #expect(first.digest == second.digest)
    }

    @Test func digestSurvivesEditsToOtherSegments() throws {
        let stable = Self.heavyClip(id: "stable")
        var edited = Self.heavyClip(id: "edited", start: 60, duration: 30)
        let before = try #require(Self.instruction([stable]).renderCacheSpan)
        edited.effects?[0].params["radius"] = EffectParam(value: 30)
        let editedSpan = try #require(Self.instruction([edited], frames: 60..<90).renderCacheSpan)
        let after = try #require(Self.instruction([stable]).renderCacheSpan)
        #expect(before.digest == after.digest)
        #expect(before.digest != editedSpan.digest)
    }

    @Test func digestChangesWhenAnEffectParameterChanges() throws {
        var edited = Self.heavyClip()
        let before = try #require(Self.instruction([Self.heavyClip()]).renderCacheSpan)
        edited.effects?[0].params["radius"] = EffectParam(value: 9)
        let after = try #require(Self.instruction([edited]).renderCacheSpan)
        #expect(before.digest != after.digest)
    }

    @Test func digestChangesWhenAnEffectIsDisabled() throws {
        var edited = Self.heavyClip()
        let before = try #require(Self.instruction([Self.heavyClip()]).renderCacheSpan)
        edited.effects?[1].enabled = false
        let after = try #require(Self.instruction([edited]).renderCacheSpan)
        #expect(before.digest != after.digest)
    }

    @Test func digestChangesWhenTheClipMoves() throws {
        var moved = Self.heavyClip()
        let before = try #require(Self.instruction([Self.heavyClip()]).renderCacheSpan)
        moved.startFrame = 5
        let after = try #require(Self.instruction([moved]).renderCacheSpan)
        #expect(before.digest != after.digest)
    }

    @Test(arguments: [24, 60])
    func digestChangesWithProjectFrameRate(fps: Int) throws {
        let base = try #require(Self.instruction([Self.heavyClip()], fps: 30).renderCacheSpan)
        let other = try #require(Self.instruction([Self.heavyClip()], fps: fps).renderCacheSpan)
        #expect(base.digest != other.digest)
    }

    @Test(arguments: [CGSize(width: 640, height: 360), CGSize(width: 1920, height: 1080)])
    func digestChangesWithRenderResolution(size: CGSize) throws {
        let base = try #require(Self.instruction([Self.heavyClip()]).renderCacheSpan)
        let other = try #require(Self.instruction([Self.heavyClip()], renderSize: size).renderCacheSpan)
        #expect(base.digest != other.digest)
    }

    @Test func digestChangesWhenTheSourceFileIsReplacedInPlace() throws {
        let clip = Self.heavyClip()
        let renderSize = CGSize(width: 320, height: 180)
        func span(tag: String) -> RenderCacheSpan? {
            let layer = LayerPlan(
                source: .track(3), clip: clip, natSize: renderSize,
                preferredTransform: .identity, mediaTag: tag
            )
            return CompositorInstruction(
                timeRange: CMTimeRange(start: .zero, duration: CMTime(value: 30, timescale: 30)),
                layers: [layer], renderSize: renderSize, fps: 30
            ).renderCacheSpan
        }
        let before = try #require(span(tag: "1024_1700000000"))
        let after = try #require(span(tag: "2048_1700000900"))
        #expect(before.digest != after.digest)
    }

    @Test func spanOrderingPrefersTheSegmentUnderThePlayhead() {
        let near = RenderCacheSpan(digest: 1, frames: 100..<130)
        let far = RenderCacheSpan(digest: 2, frames: 900..<930)
        let composition = AVMutableVideoComposition()
        composition.instructions = [
            Self.instruction([Self.heavyClip(id: "far", start: 900, duration: 30)], frames: 900..<930),
            Self.instruction([Self.heavyClip(id: "near", start: 100, duration: 30)], frames: 100..<130),
        ]
        let ordered = RenderSpanWarmer.plannedSpans(in: composition, priorityFrame: 110)
        #expect(ordered.map(\.frames) == [near.frames, far.frames])
    }
}

@Suite("Render cache — warm pass lifecycle")
struct RenderPrefetcherLifecycleTests {

    static func request() -> RenderPrefetchRequest {
        RenderPrefetchRequest(
            asset: AVMutableComposition(),
            videoComposition: AVMutableVideoComposition(),
            fps: 30,
            priorityFrame: 0,
            report: { _ in }
        )
    }

    @Test func outOfOrderRequestsNeverRevivePrefetching() async {
        let prefetcher = RenderPrefetcher()
        await prefetcher.cancel(generation: 10)
        await prefetcher.start(Self.request(), generation: 4)
        #expect(await prefetcher.isWarmPassActive == false)

        await prefetcher.start(Self.request(), generation: 11)
        #expect(await prefetcher.isWarmPassActive)

        await prefetcher.cancel(generation: 12)
        #expect(await prefetcher.isWarmPassActive == false)
    }

    @Test func sequenceNumbersStrictlyIncrease() {
        let first = RenderPrefetchSequence.next()
        let second = RenderPrefetchSequence.next()
        #expect(second > first)
    }
}

@Suite("Render cache — memory tier")
struct RenderFrameCacheTests {

    static func buffer(width: Int = 16, height: Int = 8, fill: UInt8 = 0x40) -> CVPixelBuffer {
        let payload = RenderFramePayload(
            width: width,
            height: height,
            bytesPerRow: width * 4,
            pixels: Data(repeating: fill, count: width * height * 4),
            attachments: Data()
        )
        return payload.makeBuffer()!
    }

    static func key(_ digest: UInt64, _ frame: Int) -> RenderCacheKey {
        RenderCacheKey(spanDigest: digest, frame: frame)
    }

    @Test func servesStoredFramesAtTheMatchingRenderSize() {
        let cache = RenderFrameCache(byteLimit: 1 << 20)
        cache.store(Self.buffer(), for: Self.key(7, 0))
        #expect(cache.frame(for: Self.key(7, 0), size: CGSize(width: 16, height: 8)) != nil)
        #expect(cache.frame(for: Self.key(7, 1), size: CGSize(width: 16, height: 8)) == nil)
    }

    @Test func refusesFramesRenderedAtAnotherResolution() {
        let cache = RenderFrameCache(byteLimit: 1 << 20)
        cache.store(Self.buffer(), for: Self.key(7, 0))
        #expect(cache.frame(for: Self.key(7, 0), size: CGSize(width: 32, height: 8)) == nil)
    }

    @Test func evictsTheLeastRecentlyUsedFrameWhenOverCapacity() {
        let frameBytes = CVPixelBufferGetDataSize(Self.buffer())
        let cache = RenderFrameCache(byteLimit: frameBytes * 2)
        cache.store(Self.buffer(), for: Self.key(1, 0))
        cache.store(Self.buffer(), for: Self.key(1, 1))
        _ = cache.frame(for: Self.key(1, 0), size: CGSize(width: 16, height: 8))
        cache.store(Self.buffer(), for: Self.key(1, 2))
        #expect(cache.contains(Self.key(1, 0)))
        #expect(cache.contains(Self.key(1, 2)))
        #expect(!cache.contains(Self.key(1, 1)))
        #expect(cache.statistics.bytes <= frameBytes * 2)
    }

    @Test func dropsFramesWhoseSpanLeftTheRenderGraph() {
        let cache = RenderFrameCache(byteLimit: 1 << 20)
        cache.store(Self.buffer(), for: Self.key(1, 0))
        cache.store(Self.buffer(), for: Self.key(2, 0))
        cache.retain(digests: [2])
        #expect(!cache.contains(Self.key(1, 0)))
        #expect(cache.contains(Self.key(2, 0)))
        #expect(cache.statistics.spans == 1)
    }

    @Test func rejectsFramesLargerThanTheWholeBudget() {
        let cache = RenderFrameCache(byteLimit: 8)
        cache.store(Self.buffer(), for: Self.key(1, 0))
        #expect(!cache.contains(Self.key(1, 0)))
        #expect(cache.statistics.bytes == 0)
    }
}

@Suite("Render cache — frame payloads")
struct RenderFramePayloadTests {

    static func patternPayload(width: Int = 12, height: Int = 6) -> RenderFramePayload {
        var pixels = Data(count: width * height * 4)
        for index in 0..<(width * height * 4) {
            pixels[index] = UInt8((index * 31) % 251)
        }
        return RenderFramePayload(
            width: width, height: height, bytesPerRow: width * 4,
            pixels: pixels, attachments: Data()
        )
    }

    @Test func encodingRoundTripPreservesEveryPixel() throws {
        let payload = Self.patternPayload()
        let restored = try #require(RenderFramePayload.decoded(payload.encoded()))
        #expect(restored == payload)
    }

    @Test func pixelBufferRoundTripIsBitIdentical() throws {
        let payload = Self.patternPayload()
        let buffer = try #require(payload.makeBuffer())
        let readBack = try #require(RenderFramePayload.payload(from: buffer))
        #expect(readBack.pixels == payload.pixels)
        #expect(readBack.width == payload.width)
        #expect(readBack.height == payload.height)
    }

    @Test func restoredBufferCarriesTheStoredColorTags() throws {
        let payload = Self.patternPayload()
        let source = try #require(payload.makeBuffer())
        CVBufferSetAttachment(source, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        let stored = try #require(RenderFramePayload.payload(from: source))
        let restored = try #require(stored.makeBuffer())
        let primaries = CVBufferCopyAttachment(restored, kCVImageBufferColorPrimariesKey, nil) as? String
        #expect(primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
    }

    @Test func truncatedRecordsAreRejected() {
        let encoded = Self.patternPayload().encoded()
        #expect(RenderFramePayload.decoded(encoded.dropLast(16)) == nil)
        #expect(RenderFramePayload.decoded(Data(repeating: 0, count: 4)) == nil)
    }
}

@Suite("Render cache — disk tier")
struct RenderFrameStoreTests {

    static func temporaryStore(byteLimit: Int64) -> (store: RenderFrameStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("render-cache-tests-\(UUID().uuidString)", isDirectory: true)
        return (RenderFrameStore(cache: DiskCache(directory: directory), byteLimit: byteLimit), directory)
    }

    static func payload(fill: UInt8) -> RenderFramePayload {
        RenderFramePayload(
            width: 8, height: 4, bytesPerRow: 32,
            pixels: Data(repeating: fill, count: 128), attachments: Data()
        )
    }

    @Test func storesAndReloadsAFrame() throws {
        let (store, directory) = Self.temporaryStore(byteLimit: 1 << 20)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = RenderCacheKey(spanDigest: 0xdead_beef, frame: 42)
        #expect(store.store(Self.payload(fill: 3), for: key))
        #expect(store.contains(key))
        #expect(store.payload(for: key) == Self.payload(fill: 3))
    }

    @Test func rebuildsItsIndexFromTheCacheDirectory() throws {
        let (store, directory) = Self.temporaryStore(byteLimit: 1 << 20)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = RenderCacheKey(spanDigest: 1, frame: 7)
        #expect(store.store(Self.payload(fill: 9), for: key))

        let reopened = RenderFrameStore(cache: DiskCache(directory: directory), byteLimit: 1 << 20)
        #expect(reopened.contains(key))
        #expect(reopened.payload(for: key) == Self.payload(fill: 9))
        #expect(reopened.byteCount() > 0)
    }

    @Test func evictsOldestRecordsOnceOverTheByteCap() throws {
        let recordBytes = Int64(Self.payload(fill: 0).encoded().count)
        let (store, directory) = Self.temporaryStore(byteLimit: recordBytes * 2)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = (0..<3).map { RenderCacheKey(spanDigest: 5, frame: $0) }
        for (index, key) in keys.enumerated() {
            #expect(store.store(Self.payload(fill: UInt8(index)), for: key))
        }
        #expect(!store.contains(keys[0]))
        #expect(store.contains(keys[2]))
        #expect(store.byteCount() <= recordBytes * 2)
    }

    @Test func clearingRemovesEveryRecord() throws {
        let (store, directory) = Self.temporaryStore(byteLimit: 1 << 20)
        defer { try? FileManager.default.removeItem(at: directory) }
        let key = RenderCacheKey(spanDigest: 2, frame: 1)
        #expect(store.store(Self.payload(fill: 1), for: key))
        store.clear()
        #expect(!store.contains(key))
        #expect(store.byteCount() == 0)
        #expect(store.payload(for: key) == nil)
    }

    @Test func storageNamesRoundTrip() throws {
        let key = RenderCacheKey(spanDigest: 0x0123_4567_89ab_cdef, frame: 91)
        #expect(RenderCacheKey(storageName: key.storageName) == key)
        #expect(RenderCacheKey(storageName: "not-a-key") == nil)
    }
}
