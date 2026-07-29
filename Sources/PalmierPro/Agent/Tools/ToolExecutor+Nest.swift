import Foundation

fileprivate struct ManageNestInput: DecodableToolArgs {
    let clipIds: [String]?
    let decompose: String?
    static let allowedKeys: Set<String> = ["clipIds", "decompose"]
}

extension ToolExecutor {

    // MARK: manage_nest

    func manageNest(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ManageNestInput = try decodeToolArgs(args, path: "manage_nest")
        let clipIds = input.clipIds ?? []
        guard clipIds.isEmpty != (input.decompose == nil) else {
            throw ToolError("Provide exactly one of 'clipIds' (clips to nest) or 'decompose' (a nest clip id to unpack).")
        }

        if let decomposeId = input.decompose {
            guard let clip = editor.clipFor(id: decomposeId) else {
                throw ToolError("Clip not found: \(decomposeId)")
            }
            guard clip.sourceClipType == .sequence, editor.timeline(for: clip.mediaRef) != nil else {
                throw ToolError("Clip \(decomposeId) is not a nested timeline. get_timeline reports nests as mediaType 'sequence'.")
            }
            let snapshot = timelineSnapshot(editor)
            editor.undo.perform("Decompose Nest (Agent)") {
                editor.decomposeNest(clipId: decomposeId)
            }
            return mutationResult(
                editor,
                since: snapshot,
                extra: ["decomposedTimelineId": clip.mediaRef],
                notes: ["Group-level looks on the carrier (opacity, crop, effects, fades, keyframes) are not preserved per clip."]
            )
        }

        let ids = Set(clipIds)
        guard !ids.isEmpty else { throw ToolError("clipIds is empty.") }
        for id in clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            if clip.multicamGroupId != nil {
                throw ToolError("Clip \(id) belongs to a multicam group; flatten it with change_cam before nesting.")
            }
            if clip.captionGroupId != nil {
                throw ToolError("Clip \(id) is a caption clip — nesting captions would cut them off from get_transcript and update_text.")
            }
        }

        let snapshot = timelineSnapshot(editor)
        var childId: String?
        editor.undo.perform("Nest Clips (Agent)") {
            childId = editor.nestClips(ids: ids)
        }
        guard let childId, let child = editor.timeline(for: childId) else {
            throw ToolError("Nothing was nested.")
        }
        let carriers = editor.timeline.tracks
            .flatMap(\.clips)
            .filter { $0.sourceClipType == .sequence && $0.mediaRef == childId }
            .map(\.id)
        return mutationResult(
            editor,
            since: snapshot,
            touched: carriers,
            extra: ["timelineId": childId, "timelineName": child.name, "carrierClipIds": carriers],
            notes: ["Edit the nest's contents with set_active_timeline on \(childId); the carrier clips keep the cut in place."]
        )
    }
}
