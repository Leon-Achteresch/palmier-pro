extension EditorViewModel {
    var validSelectedTimelineRange: TimelineRangeSelection? {
        guard let range = selectedTimelineRange?.normalized, range.isValid else { return nil }
        return range
    }

    func markTimelineRangeStart(atFrame frame: Int? = nil) {
        let start = max(0, frame ?? activeFrame)
        selectedTimelineRange = TimelineRangeSelection(
            startFrame: start,
            endFrame: selectedTimelineRange?.endFrame ?? start
        )
    }

    func markTimelineRangeEnd(atFrame frame: Int? = nil) {
        let end = max(0, frame ?? activeFrame)
        selectedTimelineRange = TimelineRangeSelection(
            startFrame: selectedTimelineRange?.startFrame ?? end,
            endFrame: end
        )
    }

    func setTimelineRange(startFrame: Int, endFrame: Int) {
        selectedTimelineRange = TimelineRangeSelection(
            startFrame: max(0, startFrame),
            endFrame: max(0, endFrame)
        )
    }

    func keepValidTimelineRangeOrClear() {
        guard let range = validSelectedTimelineRange else {
            selectedTimelineRange = nil
            return
        }
        selectedTimelineRange = range
    }

    func clearTimelineRange() {
        selectedTimelineRange = nil
    }

    /// Removes the selected range on every track, either lifting it (leaving a gap) or rippling the rest left.
    func deleteSelectedTimelineRange(ripple: Bool) {
        guard let selection = validSelectedTimelineRange else { return }
        let range = FrameRange(start: selection.startFrame, end: selection.endFrame)
        guard timeline.tracks.contains(where: { track in
            track.clips.contains { $0.startFrame < range.end && $0.endFrame > range.start }
        }) else { return }

        withTimelineSwap(actionName: ripple ? "Ripple Delete Range" : "Delete Range") {
            for trackIndex in timeline.tracks.indices {
                clearRegion(trackIndex: trackIndex, start: range.start, end: range.end, prune: false)
            }
            for trackIndex in timeline.tracks.indices {
                if ripple {
                    applyShifts(RippleEngine.computeRippleShiftsForRanges(
                        clips: timeline.tracks[trackIndex].clips,
                        removedRanges: [range]
                    ))
                }
                sortClips(trackIndex: trackIndex)
            }
        }
        if ripple { clearTimelineRange() }
    }
}
