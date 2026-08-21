import Foundation

fileprivate struct PartialAdjustmentSpec {
    let trackId: String?
    let startFrame: Int
    let endFrame: Int
}

extension ToolExecutor {
    private static let addAdjustmentLayersAllowedKeys: Set<String> = ["trackIndex", "startFrame", "endFrame"]

    func addAdjustmentLayers(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["entries"], path: "add_adjustment_layers")
        guard let rawEntries = args["entries"] as? [Any], !rawEntries.isEmpty else {
            throw ToolError("Missing or empty 'entries' array")
        }

        var partials: [PartialAdjustmentSpec] = []
        partials.reserveCapacity(rawEntries.count)

        for (idx, raw) in rawEntries.enumerated() {
            let path = "entries[\(idx)]"
            guard let entry = raw as? [String: Any] else {
                throw ToolError("\(path) must be an object")
            }
            try validateUnknownKeys(entry, allowed: Self.addAdjustmentLayersAllowedKeys, path: path)

            let startFrame = try entry.requireInt("startFrame")
            let endFrame = try entry.requireInt("endFrame")
            guard startFrame >= 0 else {
                throw ToolError("\(path): startFrame must be >= 0 (got \(startFrame))")
            }
            guard endFrame > startFrame else {
                throw ToolError("\(path): endFrame (\(endFrame)) must be greater than startFrame (\(startFrame))")
            }

            var trackId: String? = nil
            if let ti = entry.int("trackIndex") {
                guard editor.timeline.tracks.indices.contains(ti) else {
                    throw ToolError("\(path): track index \(ti) out of range (0..\(editor.timeline.tracks.count - 1))")
                }
                guard ClipType.adjustment.isCompatible(with: editor.timeline.tracks[ti].type) else {
                    throw ToolError("\(path): track \(ti) is an audio track; an adjustment layer needs a video track")
                }
                trackId = editor.timeline.tracks[ti].id
            }
            partials.append(.init(trackId: trackId, startFrame: startFrame, endFrame: endFrame))
        }

        let omittedCount = partials.filter { $0.trackId == nil }.count
        guard omittedCount == 0 || omittedCount == partials.count else {
            throw ToolError("Mixed trackIndex: \(omittedCount) of \(partials.count) entries omitted trackIndex. Either set it on every entry or omit it on every entry (to auto-create a shared new track).")
        }
        try Self.rejectSelfOverlaps(partials)

        let snapshot = timelineSnapshot(editor)
        let actionName = partials.count == 1 ? "Add Adjustment Layer (Agent)" : "Add Adjustment Layers (Agent)"
        try editor.undo.perform(actionName) {
            var createdTrackId: String? = nil
            if omittedCount == partials.count {
                let newIndex = editor.insertTrack(at: 0, type: .video)
                guard editor.timeline.tracks.indices.contains(newIndex) else {
                    throw ToolError("Failed to create a track for the adjustment layers")
                }
                createdTrackId = editor.timeline.tracks[newIndex].id
            }

            let specs: [EditorViewModel.AdjustmentLayerSpec] = partials.compactMap { p in
                guard let id = createdTrackId ?? p.trackId,
                      let trackIndex = editor.timeline.tracks.firstIndex(where: { $0.id == id }) else { return nil }
                return .init(
                    trackIndex: trackIndex,
                    startFrame: p.startFrame,
                    durationFrames: p.endFrame - p.startFrame
                )
            }

            let ids = editor.placeAdjustmentLayers(specs)
            guard !ids.isEmpty else {
                if let createdTrackId { editor.removeTrack(id: createdTrackId) }
                throw ToolError("Failed to place any adjustment layers")
            }

            editor.registerTimelineUndo(actionName) { vm in
                vm.removeClips(ids: Set(ids))
            }
        }
        editor.notifyTimelineChanged()
        return mutationResult(editor, since: snapshot)
    }

    private static func rejectSelfOverlaps(_ partials: [PartialAdjustmentSpec]) throws {
        for group in Dictionary(grouping: partials.indices, by: { partials[$0].trackId ?? "" }).values {
            let sorted = group.sorted { partials[$0].startFrame < partials[$1].startFrame }
            for (a, b) in zip(sorted, sorted.dropFirst()) where partials[b].startFrame < partials[a].endFrame {
                throw ToolError(
                    "entries[\(a)] [\(partials[a].startFrame), \(partials[a].endFrame)) and entries[\(b)] "
                        + "[\(partials[b].startFrame), \(partials[b].endFrame)) overlap on the same track. "
                        + "Adjustment layers on one track are sequential — use one entry per span."
                )
            }
        }
    }
}
