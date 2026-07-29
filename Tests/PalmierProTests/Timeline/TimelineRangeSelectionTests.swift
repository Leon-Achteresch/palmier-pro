import Testing
@testable import PalmierPro

@Suite("Timeline range selection")
struct TimelineRangeSelectionTests {

    @Test func normalizesReversedRanges() {
        let range = TimelineRangeSelection(startFrame: 90, endFrame: 30).normalized

        #expect(range.startFrame == 30)
        #expect(range.endFrame == 90)
        #expect(range.isValid)
    }

    @Test func containsUsesHalfOpenBounds() {
        let range = TimelineRangeSelection(startFrame: 30, endFrame: 90)

        #expect(range.contains(frame: 30))
        #expect(range.contains(frame: 89))
        #expect(!range.contains(frame: 90))
    }
}

@Suite("EditorViewModel - timeline range")
@MainActor
struct EditorTimelineRangeTests {

    @Test func markStartAndEndUsePlayhead() {
        let editor = EditorViewModel()
        editor.currentFrame = 30
        editor.markTimelineRangeStart()
        editor.currentFrame = 90
        editor.markTimelineRangeEnd()

        #expect(editor.selectedTimelineRange == TimelineRangeSelection(startFrame: 30, endFrame: 90))
    }

    @Test func invalidRangeClearsOnCommit() {
        let editor = EditorViewModel()
        editor.setTimelineRange(startFrame: 30, endFrame: 30)

        editor.keepValidTimelineRangeOrClear()

        #expect(editor.selectedTimelineRange == nil)
    }

    @Test func validSelectedTimelineRangeNormalizesAndRejectsInvalidRanges() {
        let editor = EditorViewModel()

        editor.setTimelineRange(startFrame: 90, endFrame: 30)
        #expect(editor.validSelectedTimelineRange == TimelineRangeSelection(startFrame: 30, endFrame: 90))

        editor.setTimelineRange(startFrame: 30, endFrame: 30)
        #expect(editor.validSelectedTimelineRange == nil)
    }
}

@Suite("EditorViewModel — delete timeline range")
@MainActor
struct DeleteTimelineRangeTests {

    private func editor() -> EditorViewModel {
        let e = EditorViewModel()
        e.timeline = Fixtures.timeline(tracks: [
            Fixtures.videoTrack(clips: [Fixtures.clip(id: "v1", start: 0, duration: 100)]),
            Fixtures.audioTrack(clips: [Fixtures.clip(id: "a1", start: 0, duration: 100)])
        ])
        return e
    }

    private func spans(_ track: Track) -> [[Int]] {
        track.clips.sorted { $0.startFrame < $1.startFrame }.map { [$0.startFrame, $0.endFrame] }
    }

    @Test func liftLeavesGapOnEveryTrack() {
        let e = editor()
        e.setTimelineRange(startFrame: 40, endFrame: 50)

        e.deleteSelectedTimelineRange(ripple: false)

        #expect(spans(e.timeline.tracks[0]) == [[0, 40], [50, 100]])
        #expect(spans(e.timeline.tracks[1]) == [[0, 40], [50, 100]])
        #expect(e.validSelectedTimelineRange != nil)
    }

    @Test func rippleClosesGapAndClearsRange() {
        let e = editor()
        e.setTimelineRange(startFrame: 40, endFrame: 50)

        e.deleteSelectedTimelineRange(ripple: true)

        #expect(spans(e.timeline.tracks[0]) == [[0, 40], [40, 90]])
        #expect(spans(e.timeline.tracks[1]) == [[0, 40], [40, 90]])
        #expect(e.selectedTimelineRange == nil)
    }

    @Test func rangeWithoutClipsIsNoOp() {
        let e = editor()
        let before = e.timeline
        e.setTimelineRange(startFrame: 200, endFrame: 300)

        e.deleteSelectedTimelineRange(ripple: true)

        #expect(e.timeline == before)
        #expect(e.selectedTimelineRange != nil)
    }
}
