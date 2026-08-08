import Foundation
import Testing
@testable import PalmierPro

@Suite("Audio recording placement")
@MainActor
struct AudioRecordingPlacementTests {
    @Test func recordingUsesSharedOverwriteAndUndoesAssetAndTimelineTogether() throws {
        let existing = Fixtures.clip(
            id: "existing",
            mediaRef: "existing-audio",
            mediaType: .audio,
            start: 0,
            duration: 120
        )
        let track = Fixtures.audioTrack(id: "a1", clips: [existing])
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 30, tracks: [track])
        let undoManager = UndoManager()
        editor.undo.attach(undoManager)
        let asset = recordedAsset(id: "recording-overwrite", duration: 2)

        let clipId = try editor.placeRecordedAudioAsset(
            asset,
            timelineId: editor.timeline.id,
            trackId: "a1",
            startFrame: 30
        )

        let clips = editor.timeline.tracks[0].clips.sorted { $0.startFrame < $1.startFrame }
        #expect(clips.map(\.startFrame) == [0, 30, 90])
        #expect(clips.map(\.durationFrames) == [30, 60, 30])
        #expect(clips[1].id == clipId)
        #expect(clips[1].mediaRef == asset.id)
        #expect(editor.mediaAssets.contains(where: { $0.id == asset.id }))
        #expect(undoManager.undoActionName == "Record Audio")

        undoManager.undo()

        #expect(editor.timeline.tracks[0].clips == [existing])
        #expect(!editor.mediaAssets.contains(where: { $0.id == asset.id }))
    }

    @Test func recordingResolvesTargetByStableTrackId() throws {
        let untouched = Fixtures.clip(
            id: "untouched",
            mediaRef: "existing-audio",
            mediaType: .audio,
            start: 90,
            duration: 30
        )
        let first = Fixtures.audioTrack(id: "a1", clips: [untouched])
        let target = Fixtures.audioTrack(id: "a2")
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 30, tracks: [target, first])
        let asset = recordedAsset(id: "recording-stable-track", duration: 1)

        _ = try editor.placeRecordedAudioAsset(
            asset,
            timelineId: editor.timeline.id,
            trackId: "a2",
            startFrame: 15
        )

        #expect(editor.timeline.tracks[0].id == "a2")
        #expect(editor.timeline.tracks[0].clips.first?.startFrame == 15)
        #expect(editor.timeline.tracks[1].clips == [untouched])
    }

    @Test func removedTargetRejectsWithoutImportOrUndo() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.audioTrack(id: "a1")])
        let undoManager = UndoManager()
        editor.undo.attach(undoManager)
        let asset = recordedAsset(id: "recording-removed-track", duration: 1)

        #expect(throws: EditorViewModel.AudioRecordingPlacementError.self) {
            try editor.placeRecordedAudioAsset(
                asset,
                timelineId: editor.timeline.id,
                trackId: "removed",
                startFrame: 0
            )
        }
        #expect(editor.mediaAssets.isEmpty)
        #expect(!undoManager.canUndo)
    }

    @Test func negativeStartFrameRejectsWithoutMutation() {
        let editor = EditorViewModel()
        editor.timeline = Fixtures.timeline(fps: 30, tracks: [Fixtures.audioTrack(id: "a1")])
        let asset = recordedAsset(id: "recording-negative-start", duration: 1)

        #expect(throws: EditorViewModel.AudioRecordingPlacementError.self) {
            try editor.placeRecordedAudioAsset(
                asset,
                timelineId: editor.timeline.id,
                trackId: "a1",
                startFrame: -1
            )
        }
        #expect(editor.mediaAssets.isEmpty)
        #expect(editor.timeline.tracks[0].clips.isEmpty)
    }

    private func recordedAsset(id: String, duration: Double) -> MediaAsset {
        MediaAsset(
            id: id,
            url: FileManager.default.temporaryDirectory.appendingPathComponent("\(id).caf"),
            type: .audio,
            name: "Audio Recording",
            duration: duration
        )
    }
}
