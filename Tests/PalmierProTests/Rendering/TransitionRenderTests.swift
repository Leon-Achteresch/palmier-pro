import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import PalmierPro

@Suite("Transitions — render output")
@MainActor
struct TransitionRenderTests {

    static let size = CompositorFixtures.renderSize

    struct Frame {
        let bytes: [UInt8]
        let w: Int
        func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
            let i = (y * w + x) * 4
            return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        }
        var tl: (r: Int, g: Int, b: Int) { at(80, 45) }
        var tr: (r: Int, g: Int, b: Int) { at(240, 45) }
    }

    static func timeline(_ transition: ClipTransition?) -> Timeline {
        var track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "a", mediaRef: "pattern", start: 0, duration: 30, trimStart: 30, trimEnd: 30),
            Fixtures.clip(id: "b", mediaRef: "midtone", start: 30, duration: 30, trimStart: 30, trimEnd: 30),
        ])
        if let transition { track.transitions = [transition] }
        return CompositorFixtures.timeline([track])
    }

    static func transition(
        style: TransitionStyle = .crossDissolve,
        direction: TransitionDirection? = nil,
        duration: Int = 10
    ) -> ClipTransition {
        ClipTransition(
            id: "t1", style: style, direction: direction, durationFrames: duration,
            alignment: .centered, fromClipId: "a", toClipId: "b"
        )
    }

    static func render(_ timeline: Timeline, frame: Int) async throws -> Frame {
        let urls: [String: URL] = [
            "pattern": try await CompositorFixtures.patternVideoURL(),
            "midtone": try await CompositorFixtures.midtoneVideoURL(),
        ]
        let result = try await CompositionBuilder.build(
            timeline: timeline, resolveURL: { urls[$0] }, renderSize: size
        )
        let generator = AVAssetImageGenerator(asset: result.composition)
        generator.videoComposition = result.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let cg = try await generator.image(
            at: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(timeline.fps))
        ).image
        return Frame(bytes: ColorProbeHelpers.srgbBytes(cg, size: size), w: Int(size.width))
    }

    @Test func framesOutsideTheWindowStillShowTheirOwnClip() async throws {
        let timeline = Self.timeline(Self.transition())
        let before = try await Self.render(timeline, frame: 15)
        let after = try await Self.render(timeline, frame: 45)
        #expect(CompositorFixtures.isRed(before.tl), "clip A should be untouched at 15: \(before.tl)")
        #expect(!CompositorFixtures.isRed(after.tl), "clip B should be untouched at 45: \(after.tl)")
        #expect(CompositorFixtures.isGreen(before.tr), "clip A TR at 15: \(before.tr)")
    }

    @Test func crossDissolveMixesBothNeighboursInsideTheWindow() async throws {
        let pureA = try await Self.render(Self.timeline(nil), frame: 15)
        let pureB = try await Self.render(Self.timeline(nil), frame: 45)
        let mid = try await Self.render(Self.timeline(Self.transition()), frame: 30)

        #expect(mid.tl.g > pureA.tl.g + 10, "mid \(mid.tl) should lift off pure A \(pureA.tl)")
        #expect(mid.tl.g < pureB.tl.g - 10, "mid \(mid.tl) should stay short of pure B \(pureB.tl)")
    }

    @Test func withoutATransitionTheCutStaysHard() async throws {
        let hard = try await Self.render(Self.timeline(nil), frame: 30)
        let pureB = try await Self.render(Self.timeline(nil), frame: 45)
        #expect(abs(hard.tl.g - pureB.tl.g) <= 4, "hard cut \(hard.tl) vs pure B \(pureB.tl)")
    }

    @Test func dipToBlackReachesBlackAtTheMidpoint() async throws {
        let frame = try await Self.render(Self.timeline(Self.transition(style: .dipToBlack)), frame: 30)
        #expect(CompositorFixtures.isBlack(frame.tl), "dip midpoint TL \(frame.tl)")
        #expect(CompositorFixtures.isBlack(frame.tr), "dip midpoint TR \(frame.tr)")
    }

    @Test func dipToWhiteReachesWhiteAtTheMidpoint() async throws {
        let frame = try await Self.render(Self.timeline(Self.transition(style: .dipToWhite)), frame: 30)
        #expect(CompositorFixtures.isWhite(frame.tl), "dip midpoint TL \(frame.tl)")
    }

    @Test func wipeRightRevealsTheIncomingClipFromTheLeftEdgeOnly() async throws {
        let frame = try await Self.render(
            Self.timeline(Self.transition(style: .wipe, direction: .right)), frame: 30
        )
        #expect(!CompositorFixtures.isRed(frame.at(20, 45)), "left should be clip B: \(frame.at(20, 45))")
        #expect(CompositorFixtures.isGreen(frame.at(300, 45)), "right should still be clip A: \(frame.at(300, 45))")
    }

    @Test func pushRightMovesBothNeighboursTogether() async throws {
        let frame = try await Self.render(
            Self.timeline(Self.transition(style: .push, direction: .right)), frame: 30
        )
        #expect(CompositorFixtures.isRed(frame.at(240, 45)), "A's TL should sit right of centre: \(frame.at(240, 45))")
        #expect(!CompositorFixtures.isRed(frame.at(20, 45)), "left should hold clip B: \(frame.at(20, 45))")
    }

    @Test func aStaleTransitionNeverAffectsTheRender() async throws {
        var timeline = Self.timeline(Self.transition())
        timeline.tracks[0].clips[1].startFrame = 40
        timeline.tracks[0].clips[1].durationFrames = 20
        let frame = try await Self.render(timeline, frame: 28)
        #expect(CompositorFixtures.isRed(frame.tl), "unresolvable transition must not render: \(frame.tl)")
    }
}
