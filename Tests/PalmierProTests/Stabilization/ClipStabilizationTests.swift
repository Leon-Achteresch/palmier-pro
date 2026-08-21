import Foundation
import Testing

@testable import PalmierPro

@Suite("Stabilization — clip model")
struct ClipStabilizationTests {

    private static func baked(
        smoothing: Double = 0.5,
        start: Double = 0,
        end: Double = 2,
        sampleRate: Double = 30,
        cropScale: Double = 1.2,
        samples: [StabilizationSample]? = nil
    ) -> ClipStabilization {
        ClipStabilization(
            smoothing: smoothing,
            startSourceSeconds: start,
            endSourceSeconds: end,
            sampleRate: sampleRate,
            cropScale: cropScale,
            samples: samples ?? (0..<Int((end - start) * sampleRate)).map {
                StabilizationSample(dx: Double($0) / 1000, dy: 0, rotation: 0)
            }
        )
    }

    private static func stabilizedClip(
        _ stabilization: ClipStabilization? = nil,
        duration: Int = 60,
        trimStart: Int = 0
    ) -> Clip {
        var clip = Fixtures.clip(id: "c1", start: 0, duration: duration, trimStart: trimStart)
        clip.stabilization = stabilization ?? baked()
        return clip
    }

    @Test func aRequestedBakeIsNotYetAnalyzed() {
        let requested = ClipStabilization.requested(smoothing: 0.75)

        #expect(requested.smoothing == 0.75)
        #expect(!requested.isAnalyzed)
        #expect(requested.cropPercent == 0)
        #expect(requested.sample(atSourceSeconds: 0) == nil)
    }

    @Test func cropPercentIsTheShareOfEachEdgeLostToTheZoom() {
        #expect(abs(Self.baked(cropScale: 1.25).cropPercent - 20) < 1e-9)
        #expect(Self.baked(cropScale: 1).cropPercent == 0)
    }

    @Test func sampleLookupClampsAtBothEndsOfTheAnalyzedSpan() {
        let stabilization = Self.baked()

        #expect(stabilization.sample(atSourceSeconds: -5) == stabilization.samples.first)
        #expect(stabilization.sample(atSourceSeconds: 99) == stabilization.samples.last)
        #expect(stabilization.sample(atSourceSeconds: 1) == stabilization.samples[30])
        #expect(stabilization.sample(atSourceSeconds: .nan) == nil)
    }

    @Test func packedSamplesSurviveAJSONRoundTrip() throws {
        let original = Self.baked()
        let decoded = try JSONDecoder().decode(
            ClipStabilization.self, from: JSONEncoder().encode(original)
        )

        #expect(decoded.samples.count == original.samples.count)
        #expect(decoded.sampleRate == original.sampleRate)
        #expect(abs(decoded.cropScale - original.cropScale) < 1e-6)
        for (lhs, rhs) in zip(decoded.samples, original.samples) {
            #expect(abs(lhs.dx - rhs.dx) < 1e-6)
        }
    }

    @Test func aCorruptOrNonFiniteBakeDecodesToAnUnanalyzedRequest() throws {
        let payload = Data(#"{"smoothing":4,"sampleRate":-3,"cropScale":0.2}"#.utf8)
        let decoded = try JSONDecoder().decode(ClipStabilization.self, from: payload)

        #expect(decoded.smoothing == 1)
        #expect(decoded.sampleRate == 0)
        #expect(decoded.cropScale == 1)
        #expect(!decoded.isAnalyzed)
    }

    @Test func aBakeGoesStaleOnlyWhenTheClipReadsOutsideTheAnalyzedSpan() {
        let inside = Self.stabilizedClip(Self.baked(start: 0, end: 2), duration: 60)
        let beyond = Self.stabilizedClip(Self.baked(start: 0, end: 2), duration: 60, trimStart: 90)

        #expect(!inside.stabilizationIsStale(fps: 30))
        #expect(beyond.stabilizationIsStale(fps: 30))
    }

    @Test func aRepeatedRequestAtTheSameStrengthIsANoOp() {
        let clip = Self.stabilizedClip(Self.baked(smoothing: 0.5))

        #expect(clip.stabilizationMatches(smoothing: 0.5, fps: 30))
        #expect(!clip.stabilizationMatches(smoothing: 0.9, fps: 30))
    }

    @Test func theSignatureChangesWithMediaStrengthAndSourceRange() {
        let clip = Self.stabilizedClip()
        var other = clip
        other.mediaRef = "other-media"
        var stronger = clip
        stronger.stabilization?.smoothing = 0.9
        var trimmed = clip
        trimmed.trimStartFrame = 15

        let base = clip.stabilizationSignature(fps: 30)
        #expect(base == clip.stabilizationSignature(fps: 30))
        #expect(other.stabilizationSignature(fps: 30) != base)
        #expect(stronger.stabilizationSignature(fps: 30) != base)
        #expect(trimmed.stabilizationSignature(fps: 30) != base)
    }

    @Test(arguments: [ClipType.image, .text, .audio, .adjustment])
    func nonVideoClipsAreRefused(_ type: ClipType) {
        let clip = Fixtures.clip(id: "c1", mediaType: type, start: 0, duration: 60)

        #expect(throws: StabilizationRefusal.unsupportedMedia(clipId: "c1", mediaType: type)) {
            try clip.validateStabilization(smoothing: 0.5, fps: 30)
        }
    }

    @Test func nestedTimelineClipsAreRefused() {
        var clip = Fixtures.clip(id: "nest", start: 0, duration: 60)
        clip.sourceClipType = .sequence

        #expect(throws: StabilizationRefusal.unsupportedMedia(clipId: "nest", mediaType: .video)) {
            try clip.validateStabilization(smoothing: 0.5, fps: 30)
        }
    }

    @Test func multicamMembersAreRefused() {
        var clip = Fixtures.clip(id: "angle", start: 0, duration: 60)
        clip.multicamGroupId = "group-1"

        #expect(throws: StabilizationRefusal.multicamMember(clipId: "angle")) {
            try clip.validateStabilization(smoothing: 0.5, fps: 30)
        }
    }

    @Test(arguments: [-0.1, 1.1, Double.nan, Double.infinity])
    func smoothingOutsideZeroToOneIsRefused(_ smoothing: Double) {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 60)

        #expect(throws: StabilizationRefusal.self) {
            try clip.validateStabilization(smoothing: smoothing, fps: 30)
        }
    }

    @Test func aZeroLengthClipIsRefused() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 0)

        #expect(throws: StabilizationRefusal.emptyClip(clipId: "c1")) {
            try clip.validateStabilization(smoothing: 0.5, fps: 30)
        }
    }

    @Test func aSourceRangeBeyondTheAnalysisLimitIsRefused() {
        let clip = Fixtures.clip(id: "c1", start: 0, duration: 30 * 1200)

        #expect(throws: StabilizationRefusal.self) {
            try clip.validateStabilization(smoothing: 0.5, fps: 30)
        }
    }

    @Test func aValidVideoClipPassesValidation() throws {
        try Fixtures.clip(id: "c1", start: 0, duration: 60)
            .validateStabilization(smoothing: 0.5, fps: 30)
    }
}

@Suite("Stabilization — cache key")
struct StabilizationCacheKeyTests {

    private static func key(
        mediaRef: String = "asset-1",
        assetTag: String = "1024_1700000000",
        start: Double = 0.5,
        end: Double = 4.5,
        smoothing: Double = 0.5
    ) -> StabilizationCacheKey {
        StabilizationCacheKey(
            mediaRef: mediaRef, assetTag: assetTag,
            startSourceSeconds: start, endSourceSeconds: end, smoothing: smoothing
        )
    }

    @Test func theSameRequestAlwaysProducesTheSameFilename() {
        #expect(Self.key().filename == Self.key().filename)
        #expect(Self.key().filename.hasSuffix("_v\(StabilizationCacheKey.formatVersion).json"))
    }

    @Test func subMillisecondRangeJitterDoesNotBustTheCache() {
        #expect(Self.key(start: 0.5).filename == Self.key(start: 0.50004).filename)
    }

    @Test(arguments: [
        ("asset-2", "1024_1700000000", 0.5, 4.5, 0.5),
        ("asset-1", "2048_1700000000", 0.5, 4.5, 0.5),
        ("asset-1", "1024_1700000000", 1.5, 4.5, 0.5),
        ("asset-1", "1024_1700000000", 0.5, 9.5, 0.5),
        ("asset-1", "1024_1700000000", 0.5, 4.5, 0.9),
    ])
    func anyChangedInputProducesADifferentFilename(_ input: (String, String, Double, Double, Double)) {
        let changed = Self.key(
            mediaRef: input.0, assetTag: input.1,
            start: input.2, end: input.3, smoothing: input.4
        )

        #expect(changed.filename != Self.key().filename)
    }

    @Test func filenamesStayFilesystemSafeForAwkwardMediaRefs() {
        let filename = Self.key(mediaRef: "../../etc/pa ss:wd").filename

        #expect(!filename.contains("/"))
        #expect(!filename.contains(":"))
        #expect(!filename.contains(" "))
    }

    @Test func revisionsOfTheSameMediaShareAPrefixButNotAFilename() {
        let old = Self.key(assetTag: "1024_1700000000")
        let new = Self.key(assetTag: "2048_1800000000")

        #expect(old.mediaPrefix == new.mediaPrefix)
        #expect(old.filename.hasPrefix(old.mediaPrefix))
        #expect(old.filename != new.filename)
    }
}
