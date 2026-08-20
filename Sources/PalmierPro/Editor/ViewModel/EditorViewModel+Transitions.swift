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
