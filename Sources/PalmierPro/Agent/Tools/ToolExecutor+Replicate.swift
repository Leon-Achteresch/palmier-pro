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
let copyableClipAttributes = ["transform", "crop", "opacity", "volume", "fades", "edges", "effects", "color", "keyframes", "blendMode", "textStyle", "audioMix"]

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

    private static let defaultCopiedAttributes = ["transform", "crop", "opacity", "volume", "fades", "edges", "effects", "color", "keyframes", "blendMode", "audioMix"]

    func copyAttributes(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: CopyAttributesInput = try decodeToolArgs(args, path: "copy_attributes")
        guard let source = editor.clipFor(id: input.fromClipId) else {
            throw ToolError("Clip not found: \(input.fromClipId)")
        }
        let attributes = input.attributes ?? Self.defaultCopiedAttributes
        guard !attributes.isEmpty else { throw ToolError("attributes is empty — omit it to copy the full look.") }
        let unknown = Set(attributes).subtracting(copyableClipAttributes)
        guard unknown.isEmpty else {
            throw ToolError("Unknown attribute(s) '\(unknown.sorted().joined(separator: "', '"))'. Allowed: \(copyableClipAttributes.sorted().joined(separator: ", ")).")
        }

        var targets: [String] = []
        var notes: [String] = []
        for id in input.toClipIds {
            guard id != input.fromClipId else {
                notes.append("Skipped \(id) — it is the source clip.")
                continue
            }
            guard let target = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            if attributes.contains("textStyle") && (target.mediaType != .text || source.mediaType != .text) {
                throw ToolError("'textStyle' needs a text clip on both sides (\(id) is \(target.mediaType.rawValue)).")
            }
            targets.append(id)
        }
        guard !targets.isEmpty else {
            return .ok(Self.jsonString(["status": "noop", "reason": "No target clips left after removing the source."]) ?? "{}")
        }

        let selected = Set(attributes)
        let snapshot = timelineSnapshot(editor)
        let actionName = "Copy Attributes (Agent)"
        editor.undo.perform(actionName) {
            editor.mutateClips(ids: Set(targets), actionName: actionName) { clip in
                if selected.contains("transform") { clip.transform = source.transform }
                if selected.contains("crop") { clip.crop = source.crop }
                if selected.contains("opacity") { clip.opacity = source.opacity }
                if selected.contains("volume") { clip.volume = source.volume }
                if selected.contains("fades") {
                    clip.fadeInFrames = min(source.fadeInFrames, max(0, clip.durationFrames - source.fadeOutFrames))
                    clip.fadeOutFrames = min(source.fadeOutFrames, max(0, clip.durationFrames - clip.fadeInFrames))
                    clip.fadeInInterpolation = source.fadeInInterpolation
                    clip.fadeOutInterpolation = source.fadeOutInterpolation
                }
                if selected.contains("edges") {
                    clip.edgeRounding = source.edgeRounding
                    clip.edgeSoftness = source.edgeSoftness
                }
                if selected.contains("effects") || selected.contains("color") {
                    let keepColor = !selected.contains("color")
                    let keepOther = !selected.contains("effects")
                    var stack = (clip.effects ?? []).filter { e in
                        e.type.hasPrefix("color.") ? keepColor : keepOther
                    }
                    let incoming = (source.effects ?? []).filter { e in
                        e.type.hasPrefix("color.") ? selected.contains("color") : selected.contains("effects")
                    }
                    for var e in incoming {
                        e.id = UUID().uuidString
                        stack.removeAll { $0.type == e.type }
                        stack.insert(e, at: EffectRegistry.insertIndex(stack, for: e.type))
                    }
                    clip.effects = stack.isEmpty ? nil : stack
                }
                if selected.contains("blendMode") { clip.blendMode = source.blendMode }
                if selected.contains("audioMix") { clip.audioMix = source.audioMix }
                if selected.contains("keyframes") {
                    clip.opacityTrack = source.opacityTrack
                    clip.positionTrack = source.positionTrack
                    clip.scaleTrack = source.scaleTrack
                    clip.rotationTrack = source.rotationTrack
                    clip.cropTrack = source.cropTrack
                    clip.volumeTrack = source.volumeTrack
                    clip.clampKeyframesToDuration()
                }
                if selected.contains("textStyle") {
                    clip.textStyle = source.textStyle
                    clip.textFillMode = source.textFillMode
                    clip.textAnimation = source.textAnimation
                }
            }
        }

        if selected.contains("keyframes"),
           targets.contains(where: { (editor.clipFor(id: $0)?.durationFrames ?? 0) < source.durationFrames }) {
            notes.append("Keyframes past a shorter target clip's end were dropped.")
        }
        if selected.contains("speed") {
            notes.append("Copied speed keeps each target's timeline length; retime with set_clip_properties if you want the duration to follow.")
        }
        return mutationResult(editor, since: snapshot, touched: targets, notes: notes)
    }
}
