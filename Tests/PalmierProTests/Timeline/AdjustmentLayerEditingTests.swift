import Foundation
import Testing
@testable import PalmierPro

@Suite("Adjustment layers — editing")
@MainActor
struct AdjustmentLayerEditingTests {

    private func editor(_ tracks: [Track] = [], undo: UndoManager? = nil) -> EditorViewModel {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: tracks)
        if let undo { e.undo.attach(undo) }
        return e
    }

    private func gradedLayer(start: Int = 0, duration: Int = 60) -> Clip {
        var clip = AdjustmentLayer.clip(startFrame: start, durationFrames: duration)
        clip.effects = [Effect(type: "color.exposure", params: ["ev": EffectParam(value: 1)])]
        return clip
    }

    @Test func menuActionAddsLayerOnANewTopTrackOverTheMarkedRange() throws {
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 120)])])
        e.setTimelineRange(startFrame: 24, endFrame: 96)

        let id = try #require(e.addAdjustmentLayer())

        #expect(e.timeline.tracks.count == 2)
        let clip = try #require(e.clipFor(id: id))
        #expect(e.timeline.tracks[0].clips.map(\.id) == [clip.id])
        #expect(clip.mediaType == .adjustment)
        #expect(clip.sourceClipType == .adjustment)
        #expect(clip.startFrame == 24)
        #expect(clip.durationFrames == 72)
        #expect(e.selectedClipIds == [clip.id])
    }

    @Test func menuActionFallsBackToThePlayheadWhenNothingIsMarked() throws {
        let e = editor([Fixtures.videoTrack()])
        e.currentFrame = 30

        let id = try #require(e.addAdjustmentLayer())
        let clip = try #require(e.clipFor(id: id))
        #expect(clip.startFrame == 30)
        #expect(clip.durationFrames == secondsToFrame(seconds: AdjustmentLayer.defaultDurationSeconds, fps: e.timeline.fps))
    }

    @Test func menuActionSpansTheSelectedClipsWhenNoRangeIsMarked() throws {
        let e = editor([Fixtures.videoTrack(clips: [
            Fixtures.clip(id: "c1", start: 0, duration: 30),
            Fixtures.clip(id: "c2", start: 30, duration: 30),
        ])])
        e.selectedClipIds = ["c1", "c2"]

        let id = try #require(e.addAdjustmentLayer())
        let clip = try #require(e.clipFor(id: id))
        #expect(clip.startFrame == 0)
        #expect(clip.durationFrames == 60)
    }

    @Test func addingIsOneUndoStepThatRemovesLayerAndTrack() {
        let manager = UndoManager()
        let e = editor([Fixtures.videoTrack(clips: [Fixtures.clip(id: "c1", start: 0, duration: 60)])], undo: manager)

        _ = e.addAdjustmentLayer()
        #expect(e.timeline.tracks.count == 2)

        manager.undo()
        #expect(e.timeline.tracks.count == 1)
        #expect(e.timeline.tracks[0].clips.map(\.id) == ["c1"])
        #expect(!manager.canUndo)
    }

    @Test func placingOverwritesTheRegionOnItsOwnTrackOnly() {
        let e = editor([
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "top", start: 0, duration: 60)]),
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "below", start: 0, duration: 60)]),
        ])

        let ids = e.placeAdjustmentLayers([.init(trackIndex: 0, startFrame: 0, durationFrames: 30)])

        #expect(ids.count == 1)
        #expect(e.timeline.tracks[0].clips.count == 2)
        #expect(e.clipFor(id: "top")?.startFrame == 30)
        #expect(e.clipFor(id: "below")?.startFrame == 0)
        #expect(e.clipFor(id: "below")?.durationFrames == 60)
    }

    @Test func splittingKeepsTypeAndGradeOnBothHalves() {
        let e = editor([Fixtures.videoTrack(clips: [gradedLayer()])])
        let original = e.timeline.tracks[0].clips[0].id

        _ = e.splitClip(clipId: original, atFrame: 20)

        let halves = e.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(halves.count == 2)
        #expect(halves.allSatisfy { $0.mediaType == .adjustment })
        #expect(halves.allSatisfy { $0.effects?.first?.type == "color.exposure" })
        #expect(halves[0].durationFrames == 20)
        #expect(halves[1].startFrame == 20)
        #expect(halves[1].durationFrames == 40)
    }

    @Test func trimmingTheRightEdgeExtendsBeyondAnySourceBound() {
        let e = editor([Fixtures.videoTrack(clips: [gradedLayer()])])
        let id = e.timeline.tracks[0].clips[0].id

        e.commitTrim(clipId: id, edge: .right, deltaFrames: 40, propagateToLinked: false)

        #expect(e.clipFor(id: id)?.durationFrames == 100)
    }

    @Test func movingKeepsTheSpanIntact() {
        let e = editor([Fixtures.videoTrack(clips: [gradedLayer()])])
        let id = e.timeline.tracks[0].clips[0].id

        e.moveClips([(clipId: id, toTrack: 0, toFrame: 15)])

        #expect(e.clipFor(id: id)?.startFrame == 15)
        #expect(e.clipFor(id: id)?.durationFrames == 60)
    }

    @Test func hasNoSourceRangeToSlipRetimeOrTransitionInto() {
        let clip = gradedLayer()
        let e = editor([Fixtures.videoTrack(clips: [clip])])

        #expect(!e.isSlipEligible(clip))
        #expect(!clip.supportsRetiming)
        #expect(!clip.supportsTransitions)
        #expect(!clip.hasBoundedSourceHandles)
        #expect(!e.isClipMediaOffline(clip))
    }

    @Test func survivesAProjectSaveRoundTrip() throws {
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [gradedLayer(start: 5, duration: 25)])])
        let data = try JSONEncoder().encode(timeline)
        let restored = try JSONDecoder().decode(Timeline.self, from: data)

        let clip = try #require(restored.tracks.first?.clips.first)
        #expect(clip.mediaType == .adjustment)
        #expect(clip.sourceClipType == .adjustment)
        #expect(clip.startFrame == 5)
        #expect(clip.durationFrames == 25)
        #expect(clip.effects?.first?.type == "color.exposure")
    }
}
