import Foundation
import Testing
@testable import PalmierPro

@MainActor
@Suite("EditorViewModel — asymmetric trim")
struct AsymmetricTrimTests {

    @MainActor
    private struct Pair {
        let editor: EditorViewModel
        let undoManager: UndoManager
        var video: Clip { editor.clipFor(id: "v")! }
        var audio: Clip { editor.clipFor(id: "a")! }
    }

    private func linkedPair(
        start: Int = 100,
        duration: Int = 60,
        trimStart: Int = 20,
        trimEnd: Int = 20,
        speed: Double = 1.0
    ) -> Pair {
        var video = Fixtures.clip(id: "v", start: start, duration: duration, trimStart: trimStart, trimEnd: trimEnd, speed: speed)
        video.linkGroupId = "g"
        var audio = Fixtures.clip(id: "a", mediaType: .audio, start: start, duration: duration, trimStart: trimStart, trimEnd: trimEnd, speed: speed)
        audio.linkGroupId = "g"
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [video]),
            Fixtures.audioTrack(clips: [audio]),
        ])
        let manager = UndoManager()
        manager.groupsByEvent = false
        editor.undo.attach(manager)
        return Pair(editor: editor, undoManager: manager)
    }

    @Test func optionDragRollsTheGrabbedLaneOnly() {
        let pair = linkedPair()
        #expect(pair.editor.asymmetricTrimScope(forDragOn: pair.video) == .videoOnly)
        #expect(pair.editor.asymmetricTrimScope(forDragOn: pair.audio) == .audioOnly)
        #expect(pair.editor.trimTargetIds(clipId: "v", scope: .audioOnly, propagateToLinked: true) == ["a"])
    }

    @Test func lCutExtendsOnlyTheAudioTail() {
        let pair = linkedPair()
        pair.editor.commitTrim(clipId: "v", edge: .right, deltaFrames: 12, propagateToLinked: true, scope: .audioOnly)

        #expect(pair.audio.durationFrames == 72)
        #expect(pair.audio.trimEndFrame == 8)
        #expect(pair.audio.startFrame == 100)
        #expect(pair.video.durationFrames == 60)
        #expect(pair.video.trimEndFrame == 20)
        #expect(pair.video.linkGroupId == "g")
        #expect(pair.audio.linkGroupId == "g")
    }

    @Test func jCutPullsOnlyTheAudioHeadEarlier() {
        let pair = linkedPair()
        pair.editor.commitTrim(clipId: "v", edge: .left, deltaFrames: -15, propagateToLinked: true, scope: .videoOnly)

        #expect(pair.video.startFrame == 85)
        #expect(pair.video.trimStartFrame == 5)
        #expect(pair.video.durationFrames == 75)
        #expect(pair.audio.startFrame == 100)
        #expect(pair.audio.trimStartFrame == 20)
        #expect(pair.audio.durationFrames == 60)
    }

    @Test func scopedTrimIsOneUndoEntryThatRestoresBothLanes() {
        let pair = linkedPair()
        let videoBefore = pair.video
        let audioBefore = pair.audio

        pair.editor.commitTrim(clipId: "v", edge: .right, deltaFrames: 12, propagateToLinked: true, scope: .audioOnly)
        #expect(pair.audio.durationFrames == 72)

        #expect(pair.undoManager.canUndo)
        pair.undoManager.undo()

        #expect(pair.audio == audioBefore)
        #expect(pair.video == videoBefore)
        #expect(pair.undoManager.canUndo == false)
    }

    @Test func speedMapsTheTimelineDeltaThroughSourceFrames() {
        let pair = linkedPair(trimStart: 40, trimEnd: 40, speed: 2.0)
        pair.editor.commitTrim(clipId: "a", edge: .right, deltaFrames: 10, propagateToLinked: true, scope: .videoOnly)

        #expect(pair.video.trimEndFrame == 20)
        #expect(pair.video.durationFrames == 70)
        #expect(pair.audio.durationFrames == 60)
    }

    @Test(arguments: [
        (EditorViewModel.TrimEdge.right, 21),
        (EditorViewModel.TrimEdge.left, -21),
    ])
    func refusesToExtendPastTheAvailableHandle(edge: EditorViewModel.TrimEdge, delta: Int) {
        let pair = linkedPair()
        let reason = pair.editor.trimRefusal(clipId: "v", edge: edge, deltaFrames: delta, scope: .audioOnly)
        #expect(reason?.contains("Not enough source media") == true)
        #expect(pair.editor.trimRefusal(clipId: "v", edge: edge, deltaFrames: delta / 21 * 20, scope: .audioOnly) == nil)
    }

    @Test func refusesToShrinkBelowOneFrame() {
        let pair = linkedPair()
        let reason = pair.editor.trimRefusal(clipId: "v", edge: .right, deltaFrames: -60, scope: .audioOnly)
        #expect(reason?.contains("less than 1 frame") == true)
        #expect(pair.editor.trimRefusal(clipId: "v", edge: .right, deltaFrames: -59, scope: .audioOnly) == nil)
    }

    @Test func refusesWhenTheRequestedLaneHasNoLinkedClip() {
        let clip = Fixtures.clip(id: "solo", start: 0, duration: 30, trimStart: 10, trimEnd: 10)
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [clip])])

        #expect(editor.trimTargets(clipId: "solo", scope: .audioOnly, propagateToLinked: true).isEmpty)
        let reason = editor.trimRefusal(clipId: "solo", edge: .right, deltaFrames: 5, scope: .audioOnly)
        #expect(reason?.contains("No audio clip is linked") == true)

        editor.commitTrim(clipId: "solo", edge: .right, deltaFrames: 5, propagateToLinked: true, scope: .audioOnly)
        #expect(editor.clipFor(id: "solo") == clip)
    }

    @Test func unscopedTrimStillMovesBothLanesTogether() {
        let pair = linkedPair()
        pair.editor.commitTrim(clipId: "v", edge: .right, deltaFrames: 12, propagateToLinked: true)

        #expect(pair.video.durationFrames == 72)
        #expect(pair.audio.durationFrames == 72)
    }
}
