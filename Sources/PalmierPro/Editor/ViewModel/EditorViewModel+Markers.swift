import AppKit

/// Timeline marker mutations. UI and Agent share these; every call is one undoable action.
extension EditorViewModel {

    struct MarkerEdit {
        var frame: Int?
        var name: String?
        var note: String?
        var color: MarkerColor?
        var kind: MarkerKind?
        var done: Bool?

        var isEmpty: Bool {
            frame == nil && name == nil && note == nil && color == nil && kind == nil && done == nil
        }
    }

    var markerFrameLimit: Int { max(0, timeline.totalFrames) }

    func isPlaceableMarkerFrame(_ frame: Int) -> Bool {
        frame >= 0 && frame <= markerFrameLimit
    }

    var selectedMarker: TimelineMarker? {
        selectedMarkerId.flatMap { timeline.marker(id: $0) }
    }

    func selectMarker(id: String?) {
        guard let id, timeline.marker(id: id) != nil else {
            selectedMarkerId = nil
            refreshTimelineDisplay()
            return
        }
        guard selectedMarkerId != id else { return }
        selectedMarkerId = id
        selectedClipIds.removeAll()
        selectedGap = nil
        refreshTimelineDisplay()
    }

    /// Adds a marker at `frame`. Returns nil when the frame is outside the timeline.
    @discardableResult
    func addMarker(
        atFrame frame: Int,
        kind: MarkerKind = .standard,
        name: String = "",
        note: String = "",
        color: MarkerColor = .blue,
        done: Bool = false,
        actionName: String = "Add Marker"
    ) -> TimelineMarker? {
        guard isPlaceableMarkerFrame(frame) else { return nil }
        let marker = TimelineMarker(
            frame: frame, name: name, note: note, color: color, kind: kind, done: kind == .todo && done
        )
        let changed = withMarkerChange(actionName) { $0.upsertMarker(marker) }
        guard changed else { return nil }
        selectMarker(id: marker.id)
        return marker
    }

    @discardableResult
    func addMarkerAtPlayhead(kind: MarkerKind = .standard) -> TimelineMarker? {
        let frame = min(max(0, activeFrame), markerFrameLimit)
        let marker = addMarker(atFrame: frame, kind: kind)
        if marker == nil { NSSound.beep() }
        return marker
    }

    /// Applies `edit` to one marker. Returns false when the marker is unknown, the frame is
    /// out of bounds, or nothing actually changes.
    @discardableResult
    func updateMarker(id: String, _ edit: MarkerEdit, actionName: String = "Edit Marker") -> Bool {
        guard let current = timeline.marker(id: id), !edit.isEmpty else { return false }
        if let frame = edit.frame, !isPlaceableMarkerFrame(frame) { return false }
        var updated = current
        if let frame = edit.frame { updated.frame = frame }
        if let name = edit.name { updated.name = name }
        if let note = edit.note { updated.note = note }
        if let color = edit.color { updated.color = color }
        if let kind = edit.kind { updated.kind = kind }
        if let done = edit.done { updated.done = done }
        if updated.kind != .todo { updated.done = false }
        guard updated != current else { return false }
        return withMarkerChange(actionName) { $0.upsertMarker(updated) }
    }

    @discardableResult
    func moveMarker(id: String, toFrame frame: Int) -> Bool {
        updateMarker(id: id, MarkerEdit(frame: frame), actionName: "Move Marker")
    }

    @discardableResult
    func renameMarker(id: String, to name: String) -> Bool {
        updateMarker(id: id, MarkerEdit(name: name), actionName: "Rename Marker")
    }

    /// Live position during a ruler drag. Registers nothing; `commitMarkerDrag` closes the action.
    func previewMarkerFrame(id: String, frame: Int) {
        guard isPlaceableMarkerFrame(frame), var marker = timeline.marker(id: id), marker.frame != frame else { return }
        marker.frame = frame
        undo.withoutRegistration { timeline.upsertMarker(marker) }
        refreshTimelineDisplay()
    }

    /// Closes a ruler drag as one undoable action. A drag that ended where it started registers nothing.
    @discardableResult
    func commitMarkerDrag(id: String, fromFrame: Int) -> Bool {
        guard let current = timeline.marker(id: id), current.frame != fromFrame else { return false }
        var before = timeline
        var original = current
        original.frame = fromFrame
        before.upsertMarker(original)
        if undo.isRegistrationEnabled {
            registerTimelineSwap(
                undoState: before, redoState: timeline, actionName: "Move Marker", refresh: .redraw
            )
        }
        return true
    }

    @discardableResult
    func removeMarker(id: String, actionName: String = "Delete Marker") -> Bool {
        guard timeline.marker(id: id) != nil else { return false }
        let changed = withMarkerChange(actionName) { timeline in _ = timeline.removeMarker(id: id) }
        if changed, selectedMarkerId == id { selectedMarkerId = nil }
        return changed
    }

    /// One atomic marker mutation with a timeline-swap undo. Markers don't reach the render
    /// graph, so this repaints instead of rebuilding.
    private func withMarkerChange(_ actionName: String, _ work: (inout Timeline) -> Void) -> Bool {
        let before = timeline
        undo.withoutRegistration { work(&timeline) }
        guard timeline != before else { return false }
        if undo.isRegistrationEnabled {
            registerTimelineSwap(
                undoState: before, redoState: timeline, actionName: actionName, refresh: .redraw
            )
        }
        refreshTimelineDisplay()
        return true
    }
}
