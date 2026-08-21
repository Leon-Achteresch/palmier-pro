import Foundation

// Replicating existing work: copy whole clips to new positions, or copy one clip's look onto others.
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

/// Attribute groups copy_attributes understands, shared with its tool schema.
let copyableClipAttributes = ClipAttribute.allCases.map(\.rawValue)

fileprivate struct CopyAttributesInput: DecodableToolArgs {
    let fromClipId: String
    let toClipIds: [String]
    let attributes: [String]?
    static let allowedKeys: Set<String> = ["fromClipId", "toClipIds", "attributes"]
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

    // MARK: copy_attributes

    private static let defaultCopiedAttributes: [ClipAttribute] = ClipAttribute.allCases.filter { $0 != .textStyle }

    func copyAttributes(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: CopyAttributesInput = try decodeToolArgs(args, path: "copy_attributes")
        guard let source = editor.clipFor(id: input.fromClipId) else {
            throw ToolError("Clip not found: \(input.fromClipId)")
        }
        let selected: Set<ClipAttribute>
        if let requested = input.attributes {
            guard !requested.isEmpty else { throw ToolError("attributes is empty — omit it to copy the full look.") }
            let unknown = Set(requested).subtracting(copyableClipAttributes)
            guard unknown.isEmpty else {
                throw ToolError("Unknown attribute(s) '\(unknown.sorted().joined(separator: "', '"))'. Allowed: \(copyableClipAttributes.sorted().joined(separator: ", ")).")
            }
            selected = Set(requested.compactMap(ClipAttribute.init(rawValue:)))
        } else {
            selected = Set(Self.defaultCopiedAttributes)
        }

        var targets: [String] = []
        var notes: [String] = []
        for id in input.toClipIds {
            guard id != input.fromClipId else {
                notes.append("Skipped \(id) — it is the source clip.")
                continue
            }
            guard let target = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            if selected.contains(.textStyle) && (target.mediaType != .text || source.mediaType != .text) {
                throw ToolError("'textStyle' needs a text clip on both sides (\(id) is \(target.mediaType.rawValue)).")
            }
            targets.append(id)
        }
        guard !targets.isEmpty else {
            return .ok(Self.jsonString(["status": "noop", "reason": "No target clips left after removing the source."]) ?? "{}")
        }

        let snapshot = timelineSnapshot(editor)
        let actionName = "Copy Attributes (Agent)"
        editor.undo.perform(actionName) {
            editor.mutateClips(ids: Set(targets), actionName: actionName) { clip in
                clip.absorb(selected, from: source)
            }
        }

        if selected.contains(.keyframes),
           targets.contains(where: { (editor.clipFor(id: $0)?.durationFrames ?? 0) < source.durationFrames }) {
            notes.append("Keyframes past a shorter target clip's end were dropped.")
        }
        if selected.contains(.keyframes), source.hasSpeedRamp {
            let skipped = targets.filter { id in
                guard var candidate = editor.clipFor(id: id) else { return false }
                candidate.speedTrack = source.speedTrack
                candidate.clampKeyframesToDuration()
                return (try? candidate.validateSpeedRamp(candidate.speedTrack)) == nil
            }
            if !skipped.isEmpty {
                notes.append("Speed curve not copied to \(skipped.joined(separator: ", ")) — not enough source material or unsupported media.")
            }
        }
        return mutationResult(editor, since: snapshot, touched: targets, notes: notes)
    }
}
