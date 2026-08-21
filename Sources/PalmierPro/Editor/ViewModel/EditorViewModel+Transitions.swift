import Foundation

extension EditorViewModel {

    func addTransition(
        fromClipId: String,
        toClipId: String,
        style: TransitionStyle,
        direction: TransitionDirection?,
        durationFrames: Int,
        alignment: TransitionAlignment
    ) throws(TransitionRefusal) -> ResolvedTransition {
        guard let fromLoc = findClip(id: fromClipId) else {
            throw TransitionRefusal.clipNotFound(fromClipId)
        }
        guard let toLoc = findClip(id: toClipId) else {
            throw TransitionRefusal.clipNotFound(toClipId)
        }
        guard fromLoc.trackIndex == toLoc.trackIndex else {
            throw TransitionRefusal.clipsOnDifferentTracks
        }
        let trackIndex = fromLoc.trackIndex
        let candidate = ClipTransition(
            style: style,
            direction: style.requiresDirection ? direction : nil,
            durationFrames: durationFrames,
            alignment: alignment,
            fromClipId: fromClipId,
            toClipId: toClipId
        )
        let track = timeline.tracks[trackIndex]
        let resolved = try track.resolve(candidate, against: track.resolvedTransitions)
        let trackId = track.id
        withTimelineSwap(actionName: "Add Transition") {
            guard let index = timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
            timeline.tracks[index].transitions.append(candidate)
        }
        return resolved
    }

    struct TransitionEdit {
        var style: TransitionStyle?
        var direction: TransitionDirection?
        var durationFrames: Int?
        var alignment: TransitionAlignment?

        var isEmpty: Bool {
            style == nil && direction == nil && durationFrames == nil && alignment == nil
        }
    }

    /// Applies `edit` to one transition after re-resolving it against the track. Refused and
    /// unchanged edits leave the timeline and the undo stack untouched.
    @discardableResult
    func updateTransition(
        id: String, _ edit: TransitionEdit, actionName: String = "Edit Transition"
    ) throws(TransitionRefusal) -> ResolvedTransition? {
        guard !edit.isEmpty else { return nil }
        guard let trackIndex = timeline.trackIndexOfTransition(id: id),
              let existing = timeline.tracks[trackIndex].transitions.first(where: { $0.id == id })
        else { throw TransitionRefusal.clipNotFound(id) }

        var candidate = existing
        if let style = edit.style { candidate.style = style }
        if let durationFrames = edit.durationFrames { candidate.durationFrames = durationFrames }
        if let alignment = edit.alignment { candidate.alignment = alignment }
        candidate.direction = candidate.style.requiresDirection
            ? (edit.direction ?? existing.direction ?? .left)
            : nil
        guard candidate != existing else { return timeline.tracks[trackIndex].resolvedTransition(id: id) }

        let track = timeline.tracks[trackIndex]
        let resolved = try track.resolve(candidate, against: track.resolvedTransitions.filter { $0.id != id })
        let trackId = track.id
        withTimelineSwap(actionName: actionName) {
            guard let index = timeline.tracks.firstIndex(where: { $0.id == trackId }),
                  let slot = timeline.tracks[index].transitions.firstIndex(where: { $0.id == id })
            else { return }
            timeline.tracks[index].transitions[slot] = candidate
        }
        return resolved
    }

    @discardableResult
    func removeTransition(id: String) -> ClipTransition? {
        guard let trackIndex = timeline.trackIndexOfTransition(id: id),
              let existing = timeline.tracks[trackIndex].transitions.first(where: { $0.id == id })
        else { return nil }
        let trackId = timeline.tracks[trackIndex].id
        withTimelineSwap(actionName: "Remove Transition") {
            guard let index = timeline.tracks.firstIndex(where: { $0.id == trackId }) else { return }
            timeline.tracks[index].transitions.removeAll { $0.id == id }
        }
        return existing
    }

    func removeTransitions(ids: Set<String>) -> [ClipTransition] {
        let known = timeline.tracks.flatMap(\.transitions).filter { ids.contains($0.id) }
        guard !known.isEmpty else { return [] }
        withTimelineSwap(actionName: known.count == 1 ? "Remove Transition" : "Remove Transitions") {
            for index in timeline.tracks.indices {
                timeline.tracks[index].transitions.removeAll { ids.contains($0.id) }
            }
        }
        return known
    }

    func resolvedTransition(id: String) -> (trackIndex: Int, resolved: ResolvedTransition)? {
        timeline.resolvedTransitions.first { $0.resolved.id == id }
    }
}
