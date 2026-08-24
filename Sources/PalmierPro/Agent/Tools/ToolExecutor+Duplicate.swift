import Foundation

fileprivate struct DuplicateClipsInput: DecodableToolArgs {
    let placements: [Placement]
    let includeLinked: Bool?
    static let allowedKeys: Set<String> = ["placements", "includeLinked"]

    struct Placement: DecodableToolArgs {
        let clipId: String
        let toFrame: Int
        let toTrack: Int?
        static let allowedKeys: Set<String> = ["clipId", "toFrame", "toTrack"]
    }
}

extension ToolExecutor {
    // MARK: duplicate_clips

    func duplicateClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        for (i, raw) in (args["placements"] as? [Any] ?? []).enumerated() {
            guard let entry = raw as? [String: Any] else {
                throw ToolError("duplicate_clips.placements[\(i)]: expected an object {clipId, toFrame, toTrack?}")
            }
            try validateUnknownKeys(entry, allowed: DuplicateClipsInput.Placement.allowedKeys, path: "duplicate_clips.placements[\(i)]")
        }
        let input: DuplicateClipsInput = try decodeToolArgs(args, path: "duplicate_clips")
        guard !input.placements.isEmpty else { throw ToolError("placements is empty.") }
        let includeLinked = input.includeLinked ?? true

        var placements: [ClonePlacement] = []
        var seen: Set<String> = []
        var notes: [String] = []

        func stage(clip: Clip, trackIndex: Int, atFrame: Int, path: String) throws {
            guard editor.timeline.tracks.indices.contains(trackIndex) else {
                throw ToolError("\(path): track \(trackIndex) does not exist.")
            }
            let track = editor.timeline.tracks[trackIndex]
            guard track.type.isCompatible(with: clip.mediaType) else {
                throw ToolError("\(path): track \(trackIndex) is a \(track.type.rawValue) track; clip \(clip.id) is \(clip.mediaType.rawValue).")
            }
            if clip.sourceClipType == .sequence,
               editor.wouldCreateNestCycle(nesting: clip.mediaRef, into: editor.activeTimelineId) {
                throw ToolError("\(path): duplicating this nest here would make the timeline contain itself.")
            }
            guard seen.insert("\(track.id):\(atFrame):\(clip.id)").inserted else { return }
            placements.append(ClonePlacement(source: clip, trackId: track.id, dstStart: atFrame))
        }

        for (i, p) in input.placements.enumerated() {
            let path = "duplicate_clips.placements[\(i)]"
            guard p.toFrame >= 0 else { throw ToolError("\(path): toFrame must be >= 0 (got \(p.toFrame)).") }
            guard let loc = editor.findClip(id: p.clipId) else { throw ToolError("Clip not found: \(p.clipId)") }
            let source = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            try stage(clip: source, trackIndex: p.toTrack ?? loc.trackIndex, atFrame: p.toFrame, path: path)

            guard includeLinked else { continue }
            let delta = p.toFrame - source.startFrame
            for partnerId in editor.linkedPartnerIds(of: p.clipId) {
                guard let ploc = editor.findClip(id: partnerId) else { continue }
                let partner = editor.timeline.tracks[ploc.trackIndex].clips[ploc.clipIndex]
                let partnerFrame = partner.startFrame + delta
                guard partnerFrame >= 0 else {
                    notes.append("Skipped linked partner \(partnerId) — it would land before frame 0.")
                    continue
                }
                try stage(clip: partner, trackIndex: ploc.trackIndex, atFrame: partnerFrame, path: "\(path) (linked partner)")
            }
        }

        if input.placements.contains(where: { editor.clipFor(id: $0.clipId)?.multicamGroupId != nil }) {
            notes.append("Copies of multicam clips are plain clips — they leave the multicam group and no longer follow change_cam.")
        }

        let snapshot = timelineSnapshot(editor)
        let actionName = placements.count == 1 ? "Duplicate Clip (Agent)" : "Duplicate Clips (Agent)"
        var newIds: [String] = []
        editor.undo.perform(actionName) {
            newIds = editor.cloneClipsAt(placements, actionName: actionName)
        }
        guard !newIds.isEmpty else {
            throw ToolError("Nothing was duplicated.")
        }
        return mutationResult(editor, since: snapshot, touched: newIds, extra: ["newClipIds": newIds], notes: notes)
    }

}
