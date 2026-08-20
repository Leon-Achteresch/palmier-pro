import Foundation

// manage_markers: list, add, update, and remove timeline markers in one undoable action.
extension ToolExecutor {

    private struct MarkerAddRequest {
        let marker: TimelineMarker
    }

    private struct MarkerUpdateRequest {
        let id: String
        let edit: EditorViewModel.MarkerEdit
    }

    func manageMarkers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["add", "update", "remove"], path: "manage_markers")

        let adds = try parseAdds(args["add"], editor: editor)
        let updates = try parseUpdates(args["update"], editor: editor)
        let removeIds = try parseRemovals(args["remove"], editor: editor)

        guard !adds.isEmpty || !updates.isEmpty || !removeIds.isEmpty else {
            return .ok(Self.jsonString(Self.markerListPayload(editor)) ?? "{}")
        }

        let snapshot = timelineSnapshot(editor)
        let removed = removeIds.compactMap { editor.timeline.marker(id: $0) }
        var addedIds: [String] = []
        var updatedIds: [String] = []
        var unchangedIds: [String] = []

        editor.undo.perform("Manage Markers (Agent)") {
            for request in adds {
                guard let marker = editor.addMarker(
                    atFrame: request.marker.frame,
                    kind: request.marker.kind,
                    name: request.marker.name,
                    note: request.marker.note,
                    color: request.marker.color,
                    done: request.marker.done,
                    actionName: "Manage Markers (Agent)"
                ) else { continue }
                addedIds.append(marker.id)
            }
            for request in updates {
                if editor.updateMarker(id: request.id, request.edit, actionName: "Manage Markers (Agent)") {
                    updatedIds.append(request.id)
                } else {
                    unchangedIds.append(request.id)
                }
            }
            for id in removeIds {
                editor.removeMarker(id: id, actionName: "Manage Markers (Agent)")
            }
        }

        var extra: [String: Any] = ["markers": Self.markerPayloads(editor.timeline.markers)]
        if !addedIds.isEmpty { extra["addedMarkerIds"] = addedIds }
        if !updatedIds.isEmpty { extra["updatedMarkerIds"] = updatedIds }
        if !unchangedIds.isEmpty { extra["unchangedMarkerIds"] = unchangedIds }
        if !removed.isEmpty {
            extra["removedMarkers"] = removed.map { ["markerId": $0.id, "frame": $0.frame, "name": $0.displayName] }
        }
        var notes: [String] = []
        if !unchangedIds.isEmpty {
            notes.append("\(unchangedIds.count) marker(s) already matched the requested values — no edit was made.")
        }
        return mutationResult(editor, since: snapshot, extra: extra, notes: notes)
    }

    // MARK: - Payloads

    static func markerPayloads(_ markers: [TimelineMarker]) -> [[String: Any]] {
        markers.map { marker in
            var out: [String: Any] = [
                "markerId": marker.id,
                "frame": marker.frame,
                "kind": marker.kind.rawValue,
                "color": marker.color.rawValue,
            ]
            if !marker.name.isEmpty { out["name"] = marker.name }
            if !marker.note.isEmpty { out["note"] = marker.note }
            if marker.kind == .todo { out["done"] = marker.done }
            return out
        }
    }

    private static func markerListPayload(_ editor: EditorViewModel) -> [String: Any] {
        [
            "markers": markerPayloads(editor.timeline.markers),
            "markerCount": editor.timeline.markers.count,
            "totalFrames": editor.timeline.totalFrames,
        ]
    }

    // MARK: - Parsing and validation

    private func parseAdds(_ raw: Any?, editor: EditorViewModel) throws -> [MarkerAddRequest] {
        guard let raw else { return [] }
        guard let entries = raw as? [Any] else { throw ToolError("add must be an array of marker objects") }
        return try entries.enumerated().map { index, element in
            let path = "add[\(index)]"
            guard let entry = element as? [String: Any] else { throw ToolError("\(path) must be an object") }
            try validateUnknownKeys(entry, allowed: ["frame", "name", "note", "kind", "color", "done"], path: path)
            guard entry["frame"] != nil else { throw ToolError("\(path): 'frame' is required") }
            let frame = try markerFrame(entry["frame"], editor: editor, path: path)
            let kind = try Self.markerKind(entry["kind"], path: path) ?? .standard
            let done = try Self.markerFlag(entry["done"], path: "\(path).done") ?? false
            if done, kind != .todo {
                throw ToolError("\(path): 'done' applies to todo markers only")
            }
            return MarkerAddRequest(marker: TimelineMarker(
                frame: frame,
                name: try Self.markerText(entry["name"], path: "\(path).name") ?? "",
                note: try Self.markerText(entry["note"], path: "\(path).note") ?? "",
                color: try Self.markerColor(entry["color"], path: path) ?? .blue,
                kind: kind,
                done: done
            ))
        }
    }

    private func parseUpdates(_ raw: Any?, editor: EditorViewModel) throws -> [MarkerUpdateRequest] {
        guard let raw else { return [] }
        guard let entries = raw as? [Any] else { throw ToolError("update must be an array of marker objects") }
        return try entries.enumerated().map { index, element in
            let path = "update[\(index)]"
            guard let entry = element as? [String: Any] else { throw ToolError("\(path) must be an object") }
            try validateUnknownKeys(
                entry, allowed: ["markerId", "frame", "name", "note", "kind", "color", "done"], path: path
            )
            let id = try markerId(entry["markerId"], editor: editor, path: path)
            let kind = try Self.markerKind(entry["kind"], path: path)
            let done = try Self.markerFlag(entry["done"], path: "\(path).done")
            let resolvedKind = kind ?? editor.timeline.marker(id: id)?.kind ?? .standard
            if done != nil, resolvedKind != .todo {
                throw ToolError("\(path): 'done' applies to todo markers only")
            }
            let edit = EditorViewModel.MarkerEdit(
                frame: entry["frame"] == nil ? nil : try markerFrame(entry["frame"], editor: editor, path: path),
                name: try Self.markerText(entry["name"], path: "\(path).name"),
                note: try Self.markerText(entry["note"], path: "\(path).note"),
                color: try Self.markerColor(entry["color"], path: path),
                kind: kind,
                done: done
            )
            guard !edit.isEmpty else {
                throw ToolError("\(path): pass at least one of frame, name, note, kind, color, done")
            }
            return MarkerUpdateRequest(id: id, edit: edit)
        }
    }

    private func parseRemovals(_ raw: Any?, editor: EditorViewModel) throws -> [String] {
        guard let raw else { return [] }
        guard let entries = raw as? [Any] else { throw ToolError("remove must be an array of marker ids") }
        var ids: [String] = []
        for (index, element) in entries.enumerated() {
            let id = try markerId(element, editor: editor, path: "remove[\(index)]")
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    private func markerId(_ raw: Any?, editor: EditorViewModel, path: String) throws -> String {
        guard let id = raw as? String, !id.isEmpty else {
            throw ToolError("\(path): 'markerId' is required and must be a string")
        }
        guard editor.timeline.marker(id: id) != nil else {
            throw ToolError("\(path): no marker with id '\(id)'. Call manage_markers with no arguments to list them.")
        }
        return id
    }

    private func markerFrame(_ raw: Any?, editor: EditorViewModel, path: String) throws -> Int {
        guard let raw, !isJSONBoolean(raw),
              let value = (raw as? NSNumber)?.doubleValue ?? (raw as? Int).map(Double.init),
              value.isFinite, value.rounded() == value,
              let frame = Int(exactly: value) else {
            throw ToolError("\(path): 'frame' must be a whole, finite project frame")
        }
        let limit = editor.markerFrameLimit
        guard editor.isPlaceableMarkerFrame(frame) else {
            throw ToolError("\(path): frame \(frame) is outside the timeline (0…\(limit))")
        }
        return frame
    }

    private static func markerKind(_ raw: Any?, path: String) throws -> MarkerKind? {
        guard let raw else { return nil }
        guard let value = raw as? String, let kind = MarkerKind(rawValue: value) else {
            throw ToolError("\(path): 'kind' must be one of \(MarkerKind.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return kind
    }

    private static func markerColor(_ raw: Any?, path: String) throws -> MarkerColor? {
        guard let raw else { return nil }
        guard let value = raw as? String, let color = MarkerColor(rawValue: value) else {
            throw ToolError("\(path): 'color' must be one of \(MarkerColor.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return color
    }

    private static func markerText(_ raw: Any?, path: String) throws -> String? {
        guard let raw else { return nil }
        guard let value = raw as? String else { throw ToolError("\(path): expected a string") }
        return value
    }

    private static func markerFlag(_ raw: Any?, path: String) throws -> Bool? {
        guard let raw else { return nil }
        guard isJSONBoolean(raw), let value = raw as? Bool else {
            throw ToolError("\(path): expected true or false")
        }
        return value
    }
}
