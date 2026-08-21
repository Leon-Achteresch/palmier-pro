import Foundation
import Testing
@testable import PalmierPro

@Suite("Speed ramp mapping")
struct SpeedRampTests {

    private func track(_ rows: [(Int, Double, Interpolation)]) -> KeyframeTrack<Double> {
        KeyframeTrack(keyframes: rows.map { Keyframe(frame: $0.0, value: $0.1, interpolationOut: $0.2) })
    }

    private func ramped(_ rows: [(Int, Double, Interpolation)], duration: Int, trimEnd: Int = 10_000) -> Clip {
        var clip = Fixtures.clip(start: 0, duration: duration, trimEnd: trimEnd)
        clip.speedTrack = track(rows)
        return clip
    }

    @Test(arguments: [0.5, 1.0, 2.0, 4.0])
    func aConstantCurveConsumesExactlyWhatTheConstantSpeedWouldConsume(multiplier: Double) throws {
        let clip = ramped([(0, multiplier, .linear)], duration: 100)
        let ramp = try #require(clip.speedRamp)
        var plain = clip
        plain.speedTrack = nil
        plain.speed = multiplier
        #expect(ramp.sourceFramesConsumed == plain.sourceFramesConsumed)
    }

    @Test func aLinearRampIntegratesToTheAreaUnderTheCurve() throws {
        let ramp = try #require(ramped([(0, 1.0, .linear), (60, 0.3, .linear)], duration: 60).speedRamp)
        #expect(abs(ramp.sourceOffsetTotal - 39.0) < 0.5)
        #expect(ramp.sourceFramesConsumed == 39)
    }

    @Test func aSlowMoDipConsumesLessSourceThanTheFlatClip() throws {
        let ramp = try #require(
            ramped([(0, 1.0, .linear), (30, 0.3, .linear), (60, 0.3, .linear), (90, 1.0, .linear)], duration: 90)
                .speedRamp
        )
        #expect(ramp.sourceFramesConsumed < 90)
        #expect(ramp.sourceFramesConsumed == 48)
    }

    @Test func aHoldSegmentKeepsItsDepartingRateAcrossTheJump() throws {
        let ramp = try #require(ramped([(0, 2.0, .hold), (50, 1.0, .linear)], duration: 100).speedRamp)
        #expect(ramp.sourceFramesConsumed == 150)
    }

    @Test func segmentsTileTheClipWithoutGapsOrZeroLengthPieces() throws {
        let ramp = try #require(ramped([(0, 1.0, .smooth), (45, 0.2, .smooth), (90, 3.0, .smooth)], duration: 90).speedRamp)
        #expect(ramp.segments.count <= SpeedRamp.maxSegments)
        #expect(ramp.segments.allSatisfy { $0.timelineFrames > 0 && $0.sourceFrames > 0 })
        #expect(ramp.segments.first?.clipFrame == 0)
        #expect(ramp.segments.last?.clipEndFrame == 90)
        for (a, b) in zip(ramp.segments, ramp.segments.dropFirst()) {
            #expect(a.clipEndFrame == b.clipFrame)
            #expect(abs(a.sourceEndOffset - b.sourceOffset) < 1e-9)
        }
    }

    @Test func theSegmentedSourceTotalMatchesTheMappingWithinOneFrame() throws {
        let ramp = try #require(ramped([(0, 1.0, .expoOut), (120, 0.25, .linear)], duration: 120).speedRamp)
        let summed = ramp.segments.reduce(0.0) { $0 + $1.sourceFrames }
        #expect(abs(summed - ramp.sourceOffsetTotal) < 1.0)
    }

    @Test func manyKeyframesStillProduceABoundedSegmentCount() throws {
        let rows = (0...200).map { (index: Int) -> (Int, Double, Interpolation) in
            (index * 3, index.isMultiple(of: 2) ? 0.5 : 2.0, .linear)
        }
        let ramp = try #require(ramped(rows, duration: 600).speedRamp)
        #expect(ramp.segments.count <= SpeedRamp.maxSegments)
        #expect(ramp.segments.allSatisfy { $0.timelineFrames > 0 })
    }

    @Test func theMappingIsMonotonicAndInvertible() throws {
        let ramp = try #require(ramped([(0, 1.0, .linear), (30, 0.2, .linear), (60, 2.0, .linear)], duration: 60).speedRamp)
        var previous = -1.0
        for frame in 0...60 {
            let offset = ramp.sourceOffset(atClipFrame: frame)
            #expect(offset >= previous)
            previous = offset
        }
        let midpoint = ramp.sourceOffset(atClipFrame: 30)
        #expect(ramp.clipFrame(forSourceOffset: midpoint) == 30)
        #expect(ramp.clipFrame(forSourceOffset: ramp.sourceOffsetTotal + 5) == nil)
    }

    @Test func aCurveThatOutrunsTheAvailableMediaIsRefusedWithTheMissingFrameCount() throws {
        var clip = Fixtures.clip(start: 0, duration: 100, trimStart: 0, trimEnd: 10)
        let curve = track([(0, 2.0, .linear)])
        #expect(throws: SpeedRampRefusal.self) { try clip.validateSpeedRamp(curve) }
        clip.speedTrack = curve
        do {
            try clip.validateSpeedRamp(curve)
            Issue.record("expected a refusal")
        } catch {
            #expect(error.code == "insufficient_source")
            #expect(error.missingSourceFrames == 90)
        }
    }

    @Test func aCurveThatFitsInsideTheClipsOwnSourceWindowIsAccepted() throws {
        let clip = Fixtures.clip(start: 0, duration: 100, trimStart: 20, trimEnd: 40)
        #expect(throws: Never.self) { try clip.validateSpeedRamp(track([(0, 1.35, .linear)])) }
    }

    @Test(arguments: [0.0, 0.05, 10.5, Double.infinity])
    func outOfRangeMultipliersAreRefused(multiplier: Double) throws {
        let clip = Fixtures.clip(start: 0, duration: 60, trimEnd: 10_000)
        #expect(throws: SpeedRampRefusal.self) { try clip.validateSpeedRamp(track([(0, multiplier, .linear)])) }
    }

    @Test func keyframesOutsideTheClipAreRefused() throws {
        let clip = Fixtures.clip(start: 0, duration: 60, trimEnd: 10_000)
        #expect(throws: SpeedRampRefusal.self) { try clip.validateSpeedRamp(track([(0, 1.0, .linear), (90, 1.0, .linear)])) }
    }

    @Test(arguments: [ClipType.image, .text, .sequence, .lottie])
    func mediaWithNoRedistributableSourceIsRefused(mediaType: ClipType) throws {
        var clip = Fixtures.clip(mediaType: mediaType, start: 0, duration: 60)
        clip.sourceClipType = mediaType
        #expect(throws: SpeedRampRefusal.self) { try clip.validateSpeedRamp(track([(0, 0.5, .linear)])) }
    }

    @Test func multicamClipsAreRefusedBecauseRetimingWouldSlipTheGroup() throws {
        var clip = Fixtures.clip(start: 0, duration: 60, trimEnd: 10_000)
        clip.multicamGroupId = "group"
        #expect(throws: SpeedRampRefusal.self) { try clip.validateSpeedRamp(track([(0, 0.5, .linear)])) }
    }

    @Test func anEmptyCurveLeavesTheClipOnItsConstantSpeed() throws {
        var clip = Fixtures.clip(start: 0, duration: 60, speed: 2.0)
        clip.speedTrack = KeyframeTrack(keyframes: [])
        #expect(clip.speedRamp == nil)
        #expect(clip.hasSpeedRamp == false)
        #expect(clip.rampedSourceFramesConsumed == 120)
    }

    @Test func aRampedClipRoundTripsThroughCodable() throws {
        let clip = ramped([(0, 1.0, .linear), (30, 0.3, .smooth)], duration: 60)
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(decoded.speedTrack == clip.speedTrack)
        #expect(decoded.speedRamp?.sourceFramesConsumed == clip.speedRamp?.sourceFramesConsumed)
    }

    @Test func theCacheKeepsCurvesApartByDurationAndConstantSpeed() throws {
        let curve = track([(0, 1.0, .linear), (60, 0.5, .linear)])
        let short = try #require(SpeedRampCache.ramp(track: curve, durationFrames: 60, constantSpeed: 1))
        let long = try #require(SpeedRampCache.ramp(track: curve, durationFrames: 120, constantSpeed: 1))
        #expect(short.sourceFramesConsumed != long.sourceFramesConsumed)
        #expect(SpeedRampCache.ramp(track: curve, durationFrames: 60, constantSpeed: 1) == short)
    }

    @Test func sourceSecondsMapBackThroughTheCurveNotTheConstantSpeed() throws {
        var clip = ramped([(0, 1.0, .linear), (60, 0.2, .linear)], duration: 60)
        clip.startFrame = 100
        let ramp = try #require(clip.speedRamp)
        let sourceSeconds = ramp.sourceOffset(atClipFrame: 30) / 30.0
        #expect(clip.timelineFrame(sourceSeconds: sourceSeconds, fps: 30) == 130)
    }
}

@Suite("Speed ramp and transitions")
struct SpeedRampTransitionTests {

    @Test func aTransitionIsRefusedWhenEitherNeighbourCarriesASpeedCurve() throws {
        var incoming = Fixtures.clip(id: "b", start: 30, duration: 30, trimStart: 30, trimEnd: 30)
        incoming.speedTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 1.0, interpolationOut: .linear),
            Keyframe(frame: 30, value: 0.5, interpolationOut: .linear),
        ])
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "a", start: 0, duration: 30, trimStart: 30, trimEnd: 30),
            incoming,
        ])
        let transition = ClipTransition(style: .crossDissolve, durationFrames: 10, fromClipId: "a", toClipId: "b")
        do {
            _ = try track.resolve(transition, against: [])
            Issue.record("expected a refusal")
        } catch {
            #expect(error == .speedRampOnNeighbour(clipId: "b"))
            #expect(error.code == "speed_ramp_on_neighbour")
        }
    }

    @Test func aTransitionStillResolvesWhenNeitherNeighbourIsRamped() throws {
        let track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "a", start: 0, duration: 30, trimStart: 30, trimEnd: 30),
            Fixtures.clip(id: "b", start: 30, duration: 30, trimStart: 30, trimEnd: 30),
        ])
        let transition = ClipTransition(style: .crossDissolve, durationFrames: 10, fromClipId: "a", toClipId: "b")
        #expect(throws: Never.self) { try track.resolve(transition, against: []) }
    }
}

@Suite("Speed ramp splitting")
@MainActor
struct SpeedRampSplitTests {

    @Test func splittingARampedClipDividesTheCurveAndTheSourceWindow() throws {
        var clip = Fixtures.clip(id: "a", start: 0, duration: 60, trimStart: 0, trimEnd: 100)
        clip.speedTrack = KeyframeTrack(keyframes: [
            Keyframe(frame: 0, value: 1.0, interpolationOut: .linear),
            Keyframe(frame: 60, value: 0.2, interpolationOut: .linear),
        ])
        let total = try #require(clip.speedRamp).sourceFramesConsumed
        let split = try #require(EditorViewModel.splitValues(of: clip, atFrame: 20))

        #expect(split.left.durationFrames == 20)
        #expect(split.right.durationFrames == 40)
        #expect(split.left.speedTrack?.isActive == true)
        #expect(split.right.speedTrack?.isActive == true)
        #expect(split.right.trimStartFrame + split.left.trimEndFrame == clip.trimEndFrame + total)
        let halves = try #require(split.left.speedRamp).sourceFramesConsumed
            + (try #require(split.right.speedRamp)).sourceFramesConsumed
        #expect(abs(halves - total) <= 1)
    }
}
