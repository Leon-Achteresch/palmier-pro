import Foundation
import Testing
@testable import PalmierPro

@Suite("Transitions — model")
struct TransitionModelTests {

    static func track(
        fromTrim: (start: Int, end: Int) = (30, 30),
        toTrim: (start: Int, end: Int) = (30, 30),
        mediaType: ClipType = .video
    ) -> Track {
        Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "a", mediaType: mediaType, start: 0, duration: 30,
                          trimStart: fromTrim.start, trimEnd: fromTrim.end),
            Fixtures.clip(id: "b", mediaType: mediaType, start: 30, duration: 30,
                          trimStart: toTrim.start, trimEnd: toTrim.end),
        ])
    }

    static func transition(
        style: TransitionStyle = .crossDissolve,
        direction: TransitionDirection? = nil,
        duration: Int = 10,
        alignment: TransitionAlignment = .centered
    ) -> ClipTransition {
        ClipTransition(
            id: "t1", style: style, direction: direction,
            durationFrames: duration, alignment: alignment,
            fromClipId: "a", toClipId: "b"
        )
    }

    @Test(arguments: [
        (TransitionAlignment.centered, 25, 5, 5),
        (TransitionAlignment.startAtCut, 30, 0, 10),
        (TransitionAlignment.endAtCut, 20, 10, 0),
    ])
    func alignmentPlacesTheWindowAroundTheCut(
        alignment: TransitionAlignment, start: Int, head: Int, tail: Int
    ) throws {
        let window = Self.transition(alignment: alignment).window(cutFrame: 30)
        #expect(window.startFrame == start)
        #expect(window.headFrames == head)
        #expect(window.tailFrames == tail)
        #expect(window.endFrame == start + 10)
    }

    @Test func progressNeverReachesAPureNeighbourInsideTheWindow() {
        let window = Self.transition().window(cutFrame: 30)
        #expect(window.progress(at: 25) > 0)
        #expect(window.progress(at: 34) < 1)
        #expect(window.progress(at: 30) == 0.55)
    }

    @Test func acceptsAnAdjacentCutWithEnoughHandles() throws {
        let track = Self.track()
        let resolved = try track.resolve(Self.transition(), against: [])
        #expect(resolved.window.startFrame == 25)
        #expect(resolved.window.cutFrame == 30)
        #expect(resolved.from.id == "a")
        #expect(resolved.to.id == "b")
    }

    @Test func refusesWhenTheIncomingClipHasNoHeadHandle() throws {
        let track = Self.track(toTrim: (0, 30))
        #expect(throws: TransitionRefusal.insufficientHandles(
            clipId: "b", neededSourceFrames: 5, availableSourceFrames: 0
        )) {
            try track.resolve(Self.transition(), against: [])
        }
    }

    @Test func refusesWhenTheOutgoingClipHasNoTailHandle() throws {
        let track = Self.track(fromTrim: (30, 2))
        #expect(throws: TransitionRefusal.insufficientHandles(
            clipId: "a", neededSourceFrames: 5, availableSourceFrames: 2
        )) {
            try track.resolve(Self.transition(), against: [])
        }
    }

    @Test func handleRequirementScalesWithClipSpeed() throws {
        var track = Self.track(fromTrim: (30, 9), toTrim: (30, 30))
        track.clips[0].speed = 2.0
        #expect(throws: TransitionRefusal.insufficientHandles(
            clipId: "a", neededSourceFrames: 10, availableSourceFrames: 9
        )) {
            try track.resolve(Self.transition(), against: [])
        }
    }

    @Test func startAtCutOnlyNeedsOutgoingTailHandle() throws {
        let track = Self.track(fromTrim: (0, 30), toTrim: (0, 0))
        let resolved = try track.resolve(Self.transition(alignment: .startAtCut), against: [])
        #expect(resolved.window.headFrames == 0)
        #expect(resolved.window.tailFrames == 10)
    }

    @Test func stillImagesHaveUnlimitedHandles() throws {
        let track = Self.track(fromTrim: (0, 0), toTrim: (0, 0), mediaType: .image)
        let resolved = try track.resolve(Self.transition(), against: [])
        #expect(resolved.window.durationFrames == 10)
    }

    @Test(arguments: [1, 0, -4, ClipTransition.maximumDurationFrames + 1])
    func refusesDurationsOutsideTheSupportedRange(duration: Int) throws {
        #expect(throws: TransitionRefusal.invalidDuration(duration)) {
            try Self.track().resolve(Self.transition(duration: duration), against: [])
        }
    }

    @Test func refusesNonAdjacentClips() throws {
        var track = Self.track()
        track.clips[1].startFrame = 40
        #expect(throws: TransitionRefusal.notAdjacent(fromEndFrame: 30, toStartFrame: 40)) {
            try track.resolve(Self.transition(), against: [])
        }
    }

    @Test func refusesAWindowLongerThanANeighbour() throws {
        var track = Self.track(fromTrim: (30, 60), toTrim: (60, 30))
        track.clips[0].durationFrames = 4
        track.clips[1].startFrame = 4
        #expect(throws: TransitionRefusal.windowExceedsClip(
            clipId: "a", neededFrames: 5, availableFrames: 4
        )) {
            try track.resolve(Self.transition(), against: [])
        }
    }

    @Test func refusesWhenACutEdgeCarriesAFade() throws {
        var track = Self.track()
        track.clips[0].fadeOutFrames = 4
        #expect(throws: TransitionRefusal.fadeOnCutEdge(clipId: "a")) {
            try track.resolve(Self.transition(), against: [])
        }
    }

    @Test func refusesUnsupportedMedia() throws {
        let track = Self.track(mediaType: .sequence)
        #expect(throws: TransitionRefusal.unsupportedMedia(clipId: "a", mediaType: .sequence)) {
            try track.resolve(Self.transition(), against: [])
        }
    }

    @Test func refusesADirectionOnANonDirectionalStyle() throws {
        #expect(throws: TransitionRefusal.unexpectedDirection(.crossDissolve)) {
            try Self.track().resolve(Self.transition(direction: .left), against: [])
        }
    }

    @Test func refusesADirectionalStyleWithoutADirection() throws {
        #expect(throws: TransitionRefusal.missingDirection(.wipe)) {
            try Self.track().resolve(Self.transition(style: .wipe), against: [])
        }
    }

    @Test func refusesASecondTransitionOnTheSameCut() throws {
        let track = Self.track()
        let first = try track.resolve(Self.transition(), against: [])
        var second = Self.transition()
        second.id = "t2"
        #expect(throws: TransitionRefusal.cutAlreadyHasTransition("t1")) {
            try track.resolve(second, against: [first])
        }
    }

    @Test func refusesOverlappingWindowsOnTheSameTrack() throws {
        var track = Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "a", start: 0, duration: 30, trimStart: 30, trimEnd: 30),
            Fixtures.clip(id: "b", start: 30, duration: 8, trimStart: 30, trimEnd: 30),
            Fixtures.clip(id: "c", start: 38, duration: 30, trimStart: 30, trimEnd: 30),
        ])
        track.transitions = [Self.transition()]
        let first = try #require(track.resolvedTransitions.first)
        let second = ClipTransition(
            id: "t2", style: .crossDissolve, durationFrames: 10,
            alignment: .centered, fromClipId: "b", toClipId: "c"
        )
        #expect(first.window.endFrame == 35)
        #expect(throws: TransitionRefusal.overlapsTransition("t1")) {
            try track.resolve(second, against: [first])
        }
    }

    @Test func pruningDropsATransitionWhoseCutMoved() {
        var track = Self.track()
        track.transitions = [Self.transition()]
        #expect(track.resolvedTransitions.count == 1)

        track.clips[1].startFrame = 44
        let dropped = track.pruneInvalidTransitions()
        #expect(dropped.map(\.id) == ["t1"])
        #expect(track.transitions.isEmpty)
    }

    @Test func pruningKeepsATransitionThatStillFits() {
        var track = Self.track()
        track.transitions = [Self.transition()]
        track.clips[1].opacity = 0.5
        #expect(track.pruneInvalidTransitions().isEmpty)
        #expect(track.transitions.count == 1)
    }

    @Test func extensionClipsBorrowHandlesOnBothSidesOfTheCut() throws {
        let track = Self.track()
        let resolved = try track.resolve(Self.transition(), against: [])
        let head = try #require(TransitionExtension.headClip(for: resolved))
        let tail = try #require(TransitionExtension.tailClip(for: resolved))

        #expect(head.startFrame == 25)
        #expect(head.durationFrames == 5)
        #expect(head.trimStartFrame == 25)
        #expect(tail.startFrame == 30)
        #expect(tail.durationFrames == 5)
        #expect(tail.trimStartFrame == 60)
        #expect(head.fadeInFrames == 0 && tail.fadeOutFrames == 0)
    }
}
