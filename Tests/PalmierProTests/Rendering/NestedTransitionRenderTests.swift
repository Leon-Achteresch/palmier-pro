import AVFoundation
import Foundation
import Testing
@testable import PalmierPro

@Suite("Transitions — inside a nested timeline")
@MainActor
struct NestedTransitionRenderTests {

    static func child(_ transition: ClipTransition?) -> Timeline {
        var track = Fixtures.videoTrack(id: "cv", clips: [
            Fixtures.clip(id: "a", mediaRef: "pattern", start: 0, duration: 30, trimStart: 30, trimEnd: 30),
            Fixtures.clip(id: "b", mediaRef: "midtone", start: 30, duration: 30, trimStart: 30, trimEnd: 30),
        ])
        if let transition { track.transitions = [transition] }
        return CompositorFixtures.timeline([track])
    }

    static func transition() -> ClipTransition {
        ClipTransition(
            id: "t1", style: .crossDissolve, direction: nil, durationFrames: 10,
            alignment: .centered, fromClipId: "a", toClipId: "b"
        )
    }

    static func parent(nesting child: Timeline) -> Timeline {
        let carrier = Clip(
            mediaRef: child.id, mediaType: .sequence, sourceClipType: .sequence,
            startFrame: 0, durationFrames: 60
        )
        return CompositorFixtures.timeline([Fixtures.videoTrack(clips: [carrier])])
    }

    static func render(_ child: Timeline, frame: Int) async throws -> CompositorRenderTests.Frame {
        let parent = Self.parent(nesting: child)
        return try await CompositorRenderTests.render(
            parent, frame: frame,
            imageURLs: ["midtone": try await CompositorFixtures.midtoneVideoURL()],
            timelines: [child, parent]
        )
    }

    @Test func aChildTransitionMixesBothNeighboursThroughTheNest() async throws {
        let pureA = try await Self.render(Self.child(nil), frame: 15)
        let pureB = try await Self.render(Self.child(nil), frame: 45)
        let mid = try await Self.render(Self.child(Self.transition()), frame: 30)

        let a = pureA.at(80, 45)
        let b = pureB.at(80, 45)
        let m = mid.at(80, 45)
        #expect(m.g > a.g + 10, "mid \(m) should lift off pure A \(a)")
        #expect(m.g < b.g - 10, "mid \(m) should stay short of pure B \(b)")
    }

    @Test func framesOutsideTheChildWindowStillShowTheirOwnClip() async throws {
        let nested = Self.child(Self.transition())
        let before = try await Self.render(nested, frame: 15)
        let after = try await Self.render(nested, frame: 45)
        #expect(CompositorFixtures.isRed(before.at(80, 45)), "clip A untouched at 15: \(before.at(80, 45))")
        #expect(!CompositorFixtures.isRed(after.at(80, 45)), "clip B untouched at 45: \(after.at(80, 45))")
    }

    @Test func aChildTransitionWithoutHandlesIsDroppedRatherThanRendered() async throws {
        var nested = Self.child(Self.transition())
        nested.tracks[0].clips[1].trimStartFrame = 0
        let mid = try await Self.render(nested, frame: 30)
        let pureB = try await Self.render(Self.child(nil), frame: 30)
        #expect(mid.at(80, 45) == pureB.at(80, 45), "unresolvable transition falls back to the hard cut")
    }

    @Test func flatteningCarriesChildTransitionsIntoTheParentFrameSpace() throws {
        let nested = Self.child(Self.transition())
        let carrier = Clip(
            mediaRef: nested.id, mediaType: .sequence, sourceClipType: .sequence,
            startFrame: 100, durationFrames: 60
        )
        let flat = NestFlattener.flatten(carrier: carrier, child: nested, visual: true)
        let track = try #require(flat.videoTracks.first)
        let resolved = try #require(track.resolvedTransitions.first)
        #expect(track.transitions.count == 1)
        #expect(resolved.window.cutFrame == 130)
        #expect(resolved.window.startFrame == 125)
        #expect(resolved.transition.fromClipId == "\(carrier.id)/a")
    }

    @Test func aTransitionWhoseNeighbourFallsOutsideTheCarrierWindowIsDropped() throws {
        let nested = Self.child(Self.transition())
        var carrier = Clip(
            mediaRef: nested.id, mediaType: .sequence, sourceClipType: .sequence,
            startFrame: 0, durationFrames: 20
        )
        carrier.trimStartFrame = 0
        let flat = NestFlattener.flatten(carrier: carrier, child: nested, visual: true)
        let track = try #require(flat.videoTracks.first)
        #expect(track.clips.count == 1)
        #expect(track.transitions.isEmpty)
    }
}
