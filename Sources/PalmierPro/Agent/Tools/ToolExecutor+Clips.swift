import Foundation

// MARK: - Input shapes (Decodable)

fileprivate struct AddClipsInput: DecodableToolArgs {
    let entries: [Entry]
    static let allowedKeys: Set<String> = ["entries"]

    struct Entry: DecodableToolArgs {
        let mediaRef: String
        let trackIndex: Int?
        let startFrame: Int
        let endFrame: Int?
        let source: [Double]?
        static let allowedKeys: Set<String> = ["mediaRef", "trackIndex", "startFrame", "endFrame", "source"]
    }
}

fileprivate struct InsertClipsInput: DecodableToolArgs {
    let trackIndex: Int
    let atFrame: Int
    let entries: [Entry]
    static let allowedKeys: Set<String> = ["trackIndex", "atFrame", "entries"]

    struct Entry: DecodableToolArgs {
        let mediaRef: String
        let durationFrames: Int?
        let source: [Double]?
        static let allowedKeys: Set<String> = ["mediaRef", "durationFrames", "source"]
    }
}

fileprivate struct MoveClipsInput: DecodableToolArgs {
    let moves: [Move]
    static let allowedKeys: Set<String> = ["moves"]

    struct Move: DecodableToolArgs {
        let clipId: String
        let toTrack: Int?
        let toFrame: Int?
        static let allowedKeys: Set<String> = ["clipId", "toTrack", "toFrame"]
    }
}

fileprivate struct ManageClipLinksInput: DecodableToolArgs {
    enum Action: String, Decodable {
        case link
        case unlink
    }

    let action: Action
    let clipIds: [String]
    static let allowedKeys: Set<String> = ["action", "clipIds"]
}

fileprivate struct SplitClipsInput: DecodableToolArgs {
    let splits: [Split]?
    let trackIndex: Int?
    let frames: [Int]?
    static let allowedKeys: Set<String> = ["splits", "trackIndex", "frames"]

    struct Split: DecodableToolArgs {
        let clipId: String
        let atFrame: Int
        static let allowedKeys: Set<String> = ["clipId", "atFrame"]
    }
}

fileprivate struct SetClipPropertiesInput: DecodableToolArgs {
    let clipIds: [String]?
    let durationFrames: Int?
    let trimStartFrame: Int?
    let trimEndFrame: Int?
    let speed: Double?
    let volumeDb: Double?
    let opacity: Double?
    let fadeInFrames: Int?
    let fadeOutFrames: Int?
    let fadeInInterpolation: String?
    let fadeOutInterpolation: String?
    let edgeRounding: Double?
    let edgeSoftness: Double?
    let transform: ParsedTransform?
    let crop: ParsedCrop?
    let blendMode: String?
    let audioMix: ParsedAudioMix?
    let duckingRole: String?

    static let allowedKeys: Set<String> = Set([
        "clipIds",
        "durationFrames", "trimStartFrame", "trimEndFrame", "speed",
        "volumeDb", "opacity",
        "fadeInFrames", "fadeOutFrames", "fadeInInterpolation", "fadeOutInterpolation",
        "edgeRounding", "edgeSoftness",
        "transform", "crop",
        "blendMode",
        "audioMix",
        "duckingRole",
    ])

    var hasAnyProperty: Bool {
        durationFrames != nil || trimStartFrame != nil || trimEndFrame != nil
            || speed != nil || volumeDb != nil || opacity != nil
            || fadeInFrames != nil || fadeOutFrames != nil
            || fadeInInterpolation != nil || fadeOutInterpolation != nil
            || edgeRounding != nil || edgeSoftness != nil
            || transform?.hasAnyField == true
            || crop?.hasAnyField == true
            || blendMode != nil
            || audioMix?.hasAnyField == true
            || duckingRole != nil
    }
}

fileprivate struct CopyClipSettingsInput: DecodableToolArgs {
    struct TargetTrack: Decodable {
        let trackId: String
        let range: [Int]?
    }

    let sourceClipId: String
    let targetClipIds: [String]?
    let targetTrack: TargetTrack?
    static let allowedKeys: Set<String> = ["sourceClipId", "targetClipIds", "targetTrack"]
}

fileprivate struct RippleDeleteRangesInput: DecodableToolArgs {
    let clipId: String?
    let trackIndex: Int?
    let ranges: [[Double]]
    let units: String?
    let ignoreSyncLockedTracks: [Int]?
    static let allowedKeys: Set<String> = ["clipId", "trackIndex", "ranges", "units", "ignoreSyncLockedTracks"]
}

fileprivate struct SetKeyframesInput: DecodableToolArgs {
    let clipId: String?
    let clipIds: [String]?
    let property: String?
    let mode: String?
    let stagger: Int?
    static let allowedKeys: Set<String> = ["clipId", "clipIds", "property", "keyframes", "tracks", "mode", "stagger", "repeat"]
}

struct KeyframeRepeatSpec {
    let count: Int
    let pingPong: Bool
    let gapFrames: Int
}

/// Partial transform for generic clip property updates.
struct ParsedTransform: Decodable {
    var centerX: Double?
    var centerY: Double?
    var width: Double?
    var height: Double?
    var rotation: Double?
    var flipHorizontal: Bool?
    var flipVertical: Bool?

    static let allowedKeys: Set<String> = [
        "centerX", "centerY", "width", "height", "rotation", "flipHorizontal", "flipVertical",
    ]

    var hasLayoutField: Bool {
        centerX != nil || centerY != nil || width != nil || height != nil
    }

    var hasAnyField: Bool {
        hasLayoutField || rotation != nil
            || flipHorizontal != nil || flipVertical != nil
    }

    func apply(to clip: inout Clip) {
        if let centerX { clip.transform.centerX = centerX }
        if let centerY { clip.transform.centerY = centerY }
        if let width { clip.transform.width = width }
        if let height { clip.transform.height = height }
        if let rotation { clip.transform.rotation = rotation; clip.rotationTrack = nil }
        if let flipHorizontal { clip.transform.flipHorizontal = flipHorizontal }
        if let flipVertical { clip.transform.flipVertical = flipVertical }
    }
}

/// Partial source crop for generic clip property updates. Insets are 0–1 of the source.
struct ParsedCrop: Decodable {
    var left: Double?
    var top: Double?
    var right: Double?
    var bottom: Double?

    static let allowedKeys: Set<String> = ["left", "top", "right", "bottom"]

    var hasAnyField: Bool {
        left != nil || top != nil || right != nil || bottom != nil
    }

    func merged(onto crop: Crop, path: String) throws -> Crop {
        func inset(_ value: Double?, name: String) throws -> Double? {
            guard let value else { return nil }
            guard value >= 0 else {
                throw ToolError("\(path).\(name) must be >= 0 (got \(value))")
            }
            return value
        }
        var out = crop
        if let left = try inset(left, name: "left") { out.left = left }
        if let top = try inset(top, name: "top") { out.top = top }
        if let right = try inset(right, name: "right") { out.right = right }
        if let bottom = try inset(bottom, name: "bottom") { out.bottom = bottom }
        guard out.visibleWidthFraction >= Crop.minimumVisibleFraction,
              out.visibleHeightFraction >= Crop.minimumVisibleFraction else {
            throw ToolError(
                "\(path) must leave at least \(Crop.minimumVisibleFraction) of the source visible on each axis "
                    + "(got width \(out.visibleWidthFraction), height \(out.visibleHeightFraction))"
            )
        }
        return out
    }
}

fileprivate struct AddClipSpec {
    let asset: MediaAsset
    var trackId: String?
    let startFrame: Int
    let durationFrames: Int
    let trimStartFrame: Int?
    let trimEndFrame: Int?
}

fileprivate struct ParsedMove {
    let clipId: String
    let destTrackId: String?
    let toFrame: Int?
}

// MARK: - Handlers

extension ToolExecutor {

    /// Resolves (trimStart, duration, trimEnd) for a clip placement. One length expression per
    /// domain: `source: [startSeconds, endSeconds]` picks a span of the asset (unclamped for
    /// stills — an image is an unbounded still), an exact frame count pins the timeline length.
    fileprivate func resolvePlacement(
        _ asset: MediaAsset, fps: Int,
        durationFrames: Int?, source: [Double]?, path: String, framesLabel: String = "durationFrames"
    ) throws -> (trimStart: Int, duration: Int, trimEnd: Int?) {
        guard durationFrames == nil || source == nil else {
            throw ToolError("\(path): set source OR \(framesLabel), not both — source picks a span of the asset, \(framesLabel) an exact timeline length.")
        }
        let isStill = asset.type == .image
        let sourceLen = secondsToFrame(seconds: asset.duration, fps: fps)

        if let source {
            guard source.count == 2 else {
                throw ToolError("\(path): source must be [startSeconds, endSeconds] (got \(source.count) element\(source.count == 1 ? "" : "s"))")
            }
            guard asset.duration > 0 || isStill else {
                throw ToolError("\(path): source needs a known source length; this asset has none. Use \(framesLabel).")
            }
            let start = max(source[0], 0)
            let end = isStill ? source[1] : min(source[1], asset.duration)
            guard end > start else {
                throw ToolError("\(path): source end (\(source[1])) must be greater than start (\(source[0]))\(isStill ? "" : "; source is \(asset.duration)s").")
            }
            let trimStart = secondsToFrame(seconds: start, fps: fps)
            let duration = max(1, secondsToFrame(seconds: end, fps: fps) - trimStart)
            return (trimStart, duration, nil)
        }
        if let d = durationFrames {
            guard d >= 1 else { throw ToolError("\(path): \(framesLabel) must span at least 1 frame") }
            if !isStill, sourceLen > 0, d > sourceLen {
                throw ToolError("\(path): \(framesLabel) spans \(d) frames but the source is only \(sourceLen).")
            }
            return (0, d, nil)
        }
        guard sourceLen > 0 else {
            throw ToolError("\(path): \(framesLabel) is required for this asset — its source length is unknown.")
        }
        return (0, sourceLen, nil)
    }

    // MARK: add_clips

    func addClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: AddClipsInput = try decodeToolArgs(args, path: "add_clips")
        guard !input.entries.isEmpty else { throw ToolError("Missing or empty 'entries' array") }
        // Decodable doesn't reject unknown nested keys; check each raw entry.
        if let raws = args["entries"] as? [Any] {
            for (idx, raw) in raws.enumerated() {
                if let d = raw as? [String: Any] {
                    try validateUnknownKeys(d, allowed: AddClipsInput.Entry.allowedKeys, path: "entries[\(idx)]")
                }
            }
        }

        var prepared: [(entry: AddClipsInput.Entry, asset: MediaAsset, trackId: String?)] = []
        prepared.reserveCapacity(input.entries.count)
        for (idx, entry) in input.entries.enumerated() {
            let asset = try clipSource(entry.mediaRef, editor: editor, path: "entries[\(idx)]")
            var trackId: String? = nil
            if let ti = entry.trackIndex {
                guard editor.timeline.tracks.indices.contains(ti) else {
                    throw ToolError("entries[\(idx)]: track index \(ti) out of range (0..\(editor.timeline.tracks.count - 1))")
                }
                let targetType = editor.timeline.tracks[ti].type
                guard asset.type.isCompatible(with: targetType) else {
                    throw ToolError("entries[\(idx)]: asset type \(asset.type.rawValue) is not compatible with \(targetType.rawValue) track at index \(ti)")
                }
                trackId = editor.timeline.tracks[ti].id
            }
            guard entry.startFrame >= 0 else {
                throw ToolError("entries[\(idx)]: startFrame must be >= 0 (got \(entry.startFrame))")
            }
            prepared.append((entry, asset, trackId))
        }

        // All-or-none for trackIndex: a new track at index 0 would shift any explicit indices.
        let omittedCount = prepared.filter { $0.trackId == nil }.count
        guard omittedCount == 0 || omittedCount == prepared.count else {
            throw ToolError("Mixed trackIndex: \(omittedCount) of \(prepared.count) entries omitted trackIndex. Either set it on every entry or omit it on every entry (to auto-create shared tracks).")
        }

        var specs: [AddClipSpec] = []
        specs.reserveCapacity(prepared.count)
        for (idx, p) in prepared.enumerated() {
            if let end = p.entry.endFrame, end <= p.entry.startFrame {
                throw ToolError("entries[\(idx)]: endFrame (\(end)) must be greater than startFrame (\(p.entry.startFrame))")
            }
            let place = try resolvePlacement(p.asset, fps: editor.timeline.fps,
                                             durationFrames: p.entry.endFrame.map { $0 - p.entry.startFrame },
                                             source: p.entry.source, path: "entries[\(idx)]", framesLabel: "endFrame")
            specs.append(.init(asset: p.asset, trackId: p.trackId, startFrame: p.entry.startFrame,
                               durationFrames: place.duration, trimStartFrame: place.trimStart, trimEndFrame: place.trimEnd))
        }

        let snapshot = timelineSnapshot(editor)
        let actionName = specs.count == 1 ? "Add Clip (Agent)" : "Add Clips (Agent)"
        var settingsNote: String?
        try editor.undo.perform(actionName) {
            settingsNote = applySettingsIfNeededForAgent(
                editor,
                assets: prepared.map(\.asset).filter { $0.type != .sequence }
            )
            if omittedCount == specs.count {
                let needsVideo = specs.contains { $0.asset.type != .audio }
                let needsAudio = specs.contains { $0.asset.type == .audio }
                var videoTrackId: String? = nil
                var audioTrackId: String? = nil
                if needsVideo {
                    videoTrackId = editor.timeline.tracks[editor.insertTrack(at: 0, type: .video)].id
                }
                if needsAudio {
                    audioTrackId = editor.timeline.tracks[
                        editor.insertTrack(at: editor.timeline.tracks.count, type: .audio)
                    ].id
                }
                for i in specs.indices {
                    specs[i].trackId = (specs[i].asset.type == .audio) ? audioTrackId : videoTrackId
                }
            }

            var allAdded: [String] = []
            let nonEmptyBefore = Set(editor.timeline.tracks.filter { !$0.clips.isEmpty }.map(\.id))

            let orderedIndices = specs.indices.sorted {
                let aAudio = specs[$0].asset.type == .audio ? 0 : 1
                let bAudio = specs[$1].asset.type == .audio ? 0 : 1
                if aAudio != bAudio { return aAudio < bAudio }
                return (specs[$0].trackId!, specs[$0].startFrame) < (specs[$1].trackId!, specs[$1].startFrame)
            }
            for i in orderedIndices {
                let spec = specs[i]
                let trackId = spec.trackId!
                guard let trackIdx = editor.timeline.tracks.firstIndex(where: { $0.id == trackId }) else {
                    throw ToolError("entries[\(i)]: destination track no longer exists")
                }
                editor.clearRegion(trackIndex: trackIdx, start: spec.startFrame, end: spec.startFrame + spec.durationFrames, prune: false)
                let ids = editor.placeClip(
                    asset: spec.asset, trackIndex: trackIdx,
                    startFrame: spec.startFrame, durationFrames: spec.durationFrames,
                    trimStartFrame: spec.trimStartFrame, trimEndFrame: spec.trimEndFrame
                )
                guard !ids.isEmpty else {
                    throw ToolError("entries[\(i)]: failed to place clip on track \(trackIdx) at frame \(spec.startFrame)")
                }
                allAdded.append(contentsOf: ids)
            }

            for track in editor.timeline.tracks where track.clips.isEmpty && nonEmptyBefore.contains(track.id) {
                editor.removeTrack(id: track.id)
            }

            let addedIds = allAdded
            editor.registerTimelineUndo(actionName) { vm in
                vm.removeClips(ids: Set(addedIds))
            }
        }
        editor.notifyTimelineChanged()
        return mutationResult(editor, since: snapshot, notes: settingsNote.map { [$0] } ?? [])
    }

    // MARK: insert_clips

    func insertClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: InsertClipsInput = try decodeToolArgs(args, path: "insert_clips")
        guard !input.entries.isEmpty else { throw ToolError("Missing or empty 'entries' array") }
        if let raws = args["entries"] as? [Any] {
            for (idx, raw) in raws.enumerated() {
                if let d = raw as? [String: Any] {
                    try validateUnknownKeys(d, allowed: InsertClipsInput.Entry.allowedKeys, path: "entries[\(idx)]")
                }
            }
        }
        guard editor.timeline.tracks.indices.contains(input.trackIndex) else {
            throw ToolError("trackIndex \(input.trackIndex) out of range (0..\(editor.timeline.tracks.count - 1))")
        }
        guard input.atFrame >= 0 else { throw ToolError("atFrame must be >= 0 (got \(input.atFrame))") }
        let targetType = editor.timeline.tracks[input.trackIndex].type

        var resolvedAssets: [MediaAsset] = []
        resolvedAssets.reserveCapacity(input.entries.count)
        for (idx, entry) in input.entries.enumerated() {
            let asset = try clipSource(entry.mediaRef, editor: editor, path: "entries[\(idx)]")
            guard asset.type.isCompatible(with: targetType) else {
                throw ToolError("entries[\(idx)]: asset type \(asset.type.rawValue) is not compatible with \(targetType.rawValue) track at index \(input.trackIndex)")
            }
            resolvedAssets.append(asset)
        }

        var specs: [EditorViewModel.RippleInsertSpec] = []
        specs.reserveCapacity(input.entries.count)
        for (idx, entry) in input.entries.enumerated() {
            let place = try resolvePlacement(resolvedAssets[idx], fps: editor.timeline.fps,
                                             durationFrames: entry.durationFrames,
                                             source: entry.source, path: "entries[\(idx)]")
            specs.append(.init(asset: resolvedAssets[idx], durationFrames: place.duration,
                               trimStartFrame: place.trimStart, trimEndFrame: place.trimEnd))
        }

        let snapshot = timelineSnapshot(editor)
        var settingsNote: String?
        let ids = editor.undo.perform(specs.count == 1 ? "Insert Clip (Agent)" : "Insert Clips (Agent)") {
            settingsNote = applySettingsIfNeededForAgent(
                editor,
                assets: resolvedAssets.filter { $0.type != .sequence }
            )
            return editor.rippleInsertClips(specs: specs, trackIndex: input.trackIndex, atFrame: input.atFrame)
        }
        guard !ids.isEmpty else {
            throw ToolError("Insert failed on track \(input.trackIndex) at frame \(input.atFrame)")
        }
        return mutationResult(editor, since: snapshot, notes: settingsNote.map { [$0] } ?? [])
    }

    // MARK: remove_clips

    func removeClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["clipIds", "transitionIds"], path: "remove_clips")
        let clipIds = args.stringArray("clipIds")
        let transitionIds = args.stringArray("transitionIds")
        guard !clipIds.isEmpty || !transitionIds.isEmpty else {
            throw ToolError("Provide 'clipIds', 'transitionIds', or both — both were missing or empty.")
        }
        for id in clipIds {
            guard editor.findClip(id: id) != nil else { throw ToolError("Clip not found: \(id)") }
        }
        for id in transitionIds {
            guard editor.timeline.trackIndexOfTransition(id: id) != nil else {
                throw ToolError("Transition not found: \(id). get_timeline lists each track's transitions.")
            }
        }
        let expanded = editor.expandToLinkGroup(Set(clipIds))
        let snapshot = timelineSnapshot(editor)
        var removedTransitions: [ClipTransition] = []
        editor.undo.perform(Self.removeActionName(clipCount: clipIds.count, transitionCount: transitionIds.count)) {
            if !transitionIds.isEmpty {
                removedTransitions = editor.removeTransitions(ids: Set(transitionIds))
            }
            if !expanded.isEmpty {
                editor.removeClips(ids: expanded)
            }
        }
        var extra: [String: Any] = [:]
        if !removedTransitions.isEmpty {
            extra["removedTransitionIds"] = removedTransitions.map(\.id).sorted()
        }
        return mutationResult(editor, since: snapshot, extra: extra)
    }

    private static func removeActionName(clipCount: Int, transitionCount: Int) -> String {
        if clipCount == 0 {
            return transitionCount == 1 ? "Remove Transition (Agent)" : "Remove Transitions (Agent)"
        }
        return clipCount == 1 && transitionCount == 0 ? "Remove Clip (Agent)" : "Remove Clips (Agent)"
    }

    // MARK: manage_clip_links

    func manageClipLinks(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ManageClipLinksInput = try decodeToolArgs(args, path: "manage_clip_links")
        guard !input.clipIds.isEmpty else {
            throw ToolError("manage_clip_links.clipIds must be a non-empty array")
        }
        for (index, id) in input.clipIds.enumerated() {
            guard !id.isEmpty else {
                throw ToolError("manage_clip_links.clipIds[\(index)] must be a non-empty clip ID")
            }
            guard editor.findClip(id: id) != nil else { throw ToolError("Clip not found: \(id)") }
        }

        let clipIds = Set(input.clipIds)
        let targets: Set<String>
        switch input.action {
        case .link:
            guard let resolved = editor.linkTargets(for: clipIds) else {
                throw ToolError("Link requires at least two clips of different media types that are not already one link group")
            }
            targets = resolved
        case .unlink:
            targets = editor.unlinkTargets(for: clipIds)
            guard !targets.isEmpty else { throw ToolError("None of the provided clips is linked") }
        }

        let snapshot = timelineSnapshot(editor)
        switch input.action {
        case .link:
            editor.linkClips(ids: targets)
        case .unlink:
            editor.unlinkClips(ids: targets)
        }
        return mutationResult(editor, since: snapshot, touched: Array(targets))
    }

    // MARK: move_clips

    func moveClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: MoveClipsInput = try decodeToolArgs(args, path: "move_clips")
        guard !input.moves.isEmpty else { throw ToolError("Missing or empty 'moves' array") }
        if let raws = args["moves"] as? [Any] {
            for (idx, raw) in raws.enumerated() {
                if let d = raw as? [String: Any] {
                    try validateUnknownKeys(d, allowed: MoveClipsInput.Move.allowedKeys, path: "moves[\(idx)]")
                }
            }
        }

        var parsed: [ParsedMove] = []
        parsed.reserveCapacity(input.moves.count)
        for (idx, m) in input.moves.enumerated() {
            let path = "moves[\(idx)]"
            guard m.toTrack != nil || m.toFrame != nil else {
                throw ToolError("\(path): at least one of 'toTrack' or 'toFrame' is required")
            }
            guard let loc = editor.findClip(id: m.clipId) else {
                throw ToolError("\(path): clip not found: \(m.clipId)")
            }
            var destTrackId: String? = nil
            if let ti = m.toTrack {
                guard editor.timeline.tracks.indices.contains(ti) else {
                    throw ToolError("\(path): toTrack \(ti) out of range (0..\(editor.timeline.tracks.count - 1))")
                }
                let srcType = editor.timeline.tracks[loc.trackIndex].type
                let destType = editor.timeline.tracks[ti].type
                guard destType.isCompatible(with: srcType) else {
                    throw ToolError("\(path): toTrack \(ti) (\(destType.rawValue)) is incompatible with clip's \(srcType.rawValue) source track")
                }
                destTrackId = editor.timeline.tracks[ti].id
            }
            if let f = m.toFrame, f < 0 {
                throw ToolError("\(path): toFrame must be >= 0 (got \(f))")
            }
            parsed.append(ParsedMove(clipId: m.clipId, destTrackId: destTrackId, toFrame: m.toFrame))
        }

        // Expand to linked partners via the shared model helper.
        var seen: Set<String> = Set(parsed.map(\.clipId))
        var allMoves = parsed
        for p in parsed {
            guard let toFrame = p.toFrame else { continue }
            for pm in editor.partnerMoves(forMoveOf: p.clipId, toFrame: toFrame) where !seen.contains(pm.clipId) {
                allMoves.append(ParsedMove(clipId: pm.clipId, destTrackId: nil, toFrame: pm.toFrame))
                seen.insert(pm.clipId)
            }
        }

        var moves: [(clipId: String, toTrack: Int, toFrame: Int)] = []
        for m in allMoves {
            guard let loc = editor.findClip(id: m.clipId) else { continue }
            let currentTrackIdx = loc.trackIndex
            let currentFrame = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].startFrame
            let toTrack: Int
            if let destId = m.destTrackId,
               let idx = editor.timeline.tracks.firstIndex(where: { $0.id == destId }) {
                toTrack = idx
            } else {
                toTrack = currentTrackIdx
            }
            moves.append((clipId: m.clipId, toTrack: toTrack, toFrame: m.toFrame ?? currentFrame))
        }
        if let reason = editor.multicamMoveViolation(moves: moves) {
            throw ToolError(reason)
        }

        let snapshot = timelineSnapshot(editor)
        let moveActionName = parsed.count == 1 ? "Move Clip (Agent)" : "Move Clips (Agent)"
        editor.undo.perform(moveActionName) {
            if !moves.isEmpty { editor.moveClips(moves) }
        }

        return mutationResult(editor, since: snapshot, touched: allMoves.map(\.clipId))
    }

    // MARK: swap_clip_media

    func swapClipMedia(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["clipId", "mediaRef"], path: "swap_clip_media")
        let clipId = try args.requireString("clipId")
        let replacement = try asset(args.requireString("mediaRef"), editor: editor, label: "Replacement media")
        let snapshot = timelineSnapshot(editor)
        let plan = try editor.swapClipMedia(clipId: clipId, replacement: replacement)

        return mutationResult(
            editor,
            since: snapshot,
            touched: plan.changed ? plan.affectedClipIds : [],
            extra: ["changed": plan.changed, "clipId": plan.clipId,
                    "oldMediaRef": plan.oldMediaRef, "mediaRef": plan.newMediaRef,
                    "affectedClipIds": plan.affectedClipIds]
        )
    }

    // MARK: set_clip_properties

    func setClipProperties(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        if let rawTransform = args["transform"] {
            guard let transform = rawTransform as? [String: Any] else {
                throw ToolError("set_clip_properties.transform: expected object")
            }
            try validateUnknownKeys(
                transform,
                allowed: ParsedTransform.allowedKeys,
                path: "set_clip_properties.transform"
            )
        }
        if let rawCrop = args["crop"] {
            guard let crop = rawCrop as? [String: Any] else {
                throw ToolError("set_clip_properties.crop: expected object")
            }
            try validateUnknownKeys(
                crop,
                allowed: ParsedCrop.allowedKeys,
                path: "set_clip_properties.crop"
            )
        }
        if let rawAudioMix = args["audioMix"] {
            guard let audioMix = rawAudioMix as? [String: Any] else {
                throw ToolError("set_clip_properties.audioMix: expected object")
            }
            try validateUnknownKeys(
                audioMix,
                allowed: ParsedAudioMix.allowedKeys,
                path: "set_clip_properties.audioMix"
            )
            if let eq = audioMix["eq"] {
                guard let eq = eq as? [String: Any] else {
                    throw ToolError("set_clip_properties.audioMix.eq: expected object")
                }
                try validateUnknownKeys(eq, allowed: ParsedAudioEQ.allowedKeys, path: "set_clip_properties.audioMix.eq")
            }
            if let compressor = audioMix["compressor"] {
                guard let compressor = compressor as? [String: Any] else {
                    throw ToolError("set_clip_properties.audioMix.compressor: expected object")
                }
                try validateUnknownKeys(
                    compressor,
                    allowed: ParsedAudioCompressor.allowedKeys,
                    path: "set_clip_properties.audioMix.compressor"
                )
            }
        }
        let input: SetClipPropertiesInput = try decodeToolArgs(args, path: "set_clip_properties")
        let clipIds = input.clipIds ?? []
        guard !clipIds.isEmpty else { throw ToolError("Provide a non-empty 'clipIds' array") }
        guard input.hasAnyProperty else {
            throw ToolError("set_clip_properties needs at least one property to apply")
        }
        if let df = input.durationFrames, df < 1 {
            throw ToolError("durationFrames must be >= 1 (got \(df))")
        }
        if let s = input.speed, s <= 0 {
            throw ToolError("speed must be > 0 (got \(s))")
        }
        if let v = input.volumeDb, !(VolumeScale.floorDb...VolumeScale.ceilingDb).contains(v) {
            throw ToolError("volumeDb must be between \(VolumeScale.floorDb) and +\(VolumeScale.ceilingDb) dB (got \(v))")
        }
        if let o = input.opacity, !(0...1).contains(o) {
            throw ToolError("opacity must be between 0 and 1 (got \(o))")
        }
        if let frames = input.fadeInFrames, frames < 0 {
            throw ToolError("fadeInFrames must be >= 0 (got \(frames))")
        }
        if let frames = input.fadeOutFrames, frames < 0 {
            throw ToolError("fadeOutFrames must be >= 0 (got \(frames))")
        }
        let fadeInInterpolation = try Self.fadeInterpolation(
            input.fadeInInterpolation,
            field: "fadeInInterpolation"
        )
        let fadeOutInterpolation = try Self.fadeInterpolation(
            input.fadeOutInterpolation,
            field: "fadeOutInterpolation"
        )
        for (name, value) in [
            ("edgeRounding", input.edgeRounding),
            ("edgeSoftness", input.edgeSoftness),
        ] {
            guard let value else { continue }
            guard value.isFinite, (0...1).contains(value) else {
                throw ToolError("\(name) must be between 0 and 1 (got \(value))")
            }
        }
        if let audioMix = input.audioMix {
            try audioMix.validated(path: "set_clip_properties.audioMix")
        }
        var duckingRole: DuckingRole?
        if let raw = input.duckingRole {
            guard let parsed = DuckingRole(rawValue: raw) else {
                throw ToolError(
                    "invalid duckingRole '\(raw)'. Valid: \(DuckingRole.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            duckingRole = parsed
        }
        if let t = input.trimStartFrame, t < 0 {
            throw ToolError("trimStartFrame must be >= 0 (got \(t))")
        }
        if let t = input.trimEndFrame, t < 0 {
            throw ToolError("trimEndFrame must be >= 0 (got \(t))")
        }

        // Resolve clipIds + collect clips for validation.
        var targetClips: [String: Clip] = [:]
        for id in clipIds {
            guard let loc = editor.findClip(id: id) else { throw ToolError("Clip not found: \(id)") }
            targetClips[id] = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        }

        if clipIds.contains(where: { editor.clipFor(id: $0)?.multicamGroupId != nil }),
           input.trimStartFrame != nil || input.trimEndFrame != nil || input.durationFrames != nil || input.speed != nil {
            throw ToolError("Timing fields would slip a multicam clip out of sync — switch angles with change_cam; split/delete and property fields (volumeDb, opacity, edgeRounding, edgeSoftness, transform, crop) stay editable.")
        }

        if input.fadeInFrames != nil || input.fadeOutFrames != nil {
            for id in clipIds {
                guard var candidate = targetClips[id] else { continue }
                _ = Self.applyTimingChanges(
                    durationFrames: input.durationFrames,
                    trimStartFrame: input.trimStartFrame,
                    trimEndFrame: input.trimEndFrame,
                    speed: input.speed,
                    to: &candidate
                )
                let fadeInFrames = input.fadeInFrames ?? candidate.fadeInFrames
                let fadeOutFrames = input.fadeOutFrames ?? candidate.fadeOutFrames
                guard fadeInFrames <= candidate.durationFrames,
                      fadeOutFrames <= candidate.durationFrames - fadeInFrames else {
                    throw ToolError(
                        "Fades for clip \(id) must fit within its resulting duration of \(candidate.durationFrames) frames "
                            + "(fadeInFrames \(fadeInFrames) + fadeOutFrames \(fadeOutFrames))"
                    )
                }
            }
        }

        // blendMode applies only to visual (video/image) clips. "normal" clears it.
        var blendMode: BlendMode?
        let setBlendMode = input.blendMode != nil
        if let raw = input.blendMode {
            let nonVisual = targetClips.filter {
                $0.value.mediaType.isSourcelessLayer || $0.value.mediaType == .audio
            }.map(\.key).sorted()
            if !nonVisual.isEmpty {
                throw ToolError("blendMode only applies to video/image clips: \(nonVisual.joined(separator: ", "))")
            }
            if raw != "normal" {
                guard let m = BlendMode(rawValue: raw) else {
                    throw ToolError("invalid blendMode '\(raw)'. Valid: \(BlendMode.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                blendMode = m
            }
        }
        if input.audioMix != nil {
            let unsupported = targetClips.filter { $0.value.mediaType != .audio }.map(\.key).sorted()
            if !unsupported.isEmpty {
                throw ToolError(
                    "audioMix only applies to audio clips: \(unsupported.joined(separator: ", ")). "
                        + "A video clip's sound is its nested audio.id from get_timeline — pass that id instead."
                )
            }
        }
        if duckingRole != nil {
            let unsupported = targetClips.filter { $0.value.mediaType != .audio }.map(\.key).sorted()
            if !unsupported.isEmpty {
                throw ToolError(
                    "duckingRole only applies to audio clips: \(unsupported.joined(separator: ", ")). "
                        + "A video clip's sound is its nested audio.id from get_timeline — pass that id instead."
                )
            }
        }
        if input.edgeRounding != nil || input.edgeSoftness != nil {
            let unsupported = targetClips.filter {
                $0.value.mediaType == .audio || $0.value.mediaType.isSourcelessLayer
            }.map(\.key).sorted()
            if !unsupported.isEmpty {
                throw ToolError("edgeRounding and edgeSoftness only apply to visual clips with source media: \(unsupported.joined(separator: ", "))")
            }
        }
        if input.trimStartFrame != nil || input.trimEndFrame != nil || input.speed != nil {
            let unsupported = targetClips.filter { $0.value.isAdjustmentLayer }.map(\.key).sorted()
            if !unsupported.isEmpty {
                throw ToolError(
                    "Adjustment layers have no source media, so trims and speed don't apply: \(unsupported.joined(separator: ", ")). "
                        + "Use durationFrames, move_clips, or trim_clips to change the span they cover."
                )
            }
        }
        var crops: [String: Crop] = [:]
        if let parsedCrop = input.crop, parsedCrop.hasAnyField {
            let unsupported = targetClips.filter {
                $0.value.mediaType == .audio || $0.value.mediaType == .text
            }.map(\.key).sorted()
            if !unsupported.isEmpty {
                throw ToolError("crop only applies to non-text visual clips: \(unsupported.joined(separator: ", "))")
            }
            for id in clipIds {
                guard let clip = targetClips[id] else { continue }
                crops[id] = try parsedCrop.merged(
                    onto: clip.cropAt(frame: editor.activeFrame),
                    path: "set_clip_properties.crop"
                )
            }
        }

        // Expand timing fields to linked partners via the shared model helper.
        // Partners drop trim/speed when they're text — handled per-partner below.
        let propagatesTiming = input.durationFrames != nil || input.trimStartFrame != nil
            || input.trimEndFrame != nil || input.speed != nil
        let partners: Set<String> = propagatesTiming
            ? editor.timingPropagationPartners(of: Set(clipIds))
            : []

        var notes: [String] = []
        let clearedKeyframes = clipIds.filter { id in
            guard let loc = editor.findClip(id: id) else { return false }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            return (input.volumeDb != nil && clip.volumeTrack != nil)
                || (input.opacity != nil && clip.opacityTrack != nil)
                || (input.transform?.rotation != nil && clip.rotationTrack != nil)
                || (input.crop?.hasAnyField == true && clip.cropTrack != nil)
        }
        if !clearedKeyframes.isEmpty {
            notes.append("Setting a static value cleared existing keyframes on: \(clearedKeyframes.joined(separator: ", ")).")
        }

        var beforeClips: [String: Clip] = [:]
        for id in clipIds + Array(partners) {
            beforeClips[id] = editor.clipFor(id: id)
        }

        let snapshot = timelineSnapshot(editor)
        let setActionName = clipIds.count == 1 ? "Set Clip Property (Agent)" : "Set Clip Properties (Agent)"
        editor.undo.perform(setActionName) {
            for id in clipIds {
                let changed = Self.applyPropertyChanges(
                    durationFrames: input.durationFrames,
                    trimStartFrame: input.trimStartFrame,
                    trimEndFrame: input.trimEndFrame,
                    speed: input.speed,
                    volumeDb: input.volumeDb,
                    opacity: input.opacity,
                    fadeInFrames: input.fadeInFrames,
                    fadeOutFrames: input.fadeOutFrames,
                    fadeInInterpolation: fadeInInterpolation,
                    fadeOutInterpolation: fadeOutInterpolation,
                    edgeRounding: input.edgeRounding,
                    edgeSoftness: input.edgeSoftness,
                    transform: input.transform,
                    crop: crops[id],
                    blendMode: blendMode,
                    setBlendMode: setBlendMode,
                    audioMix: input.audioMix,
                    duckingRole: duckingRole,
                    clipId: id,
                    editor: editor
                )
                notes.append(contentsOf: changed.filter { $0.contains("skipped") }.map { "\(id): \($0)" })
            }
            for partnerId in partners {
                guard let pLoc = editor.findClip(id: partnerId) else { continue }
                let partnerIsText = editor.timeline.tracks[pLoc.trackIndex].clips[pLoc.clipIndex].mediaType == .text
                _ = Self.applyPropertyChanges(
                    durationFrames: input.durationFrames,
                    trimStartFrame: partnerIsText ? nil : input.trimStartFrame,
                    trimEndFrame:   partnerIsText ? nil : input.trimEndFrame,
                    speed:          partnerIsText ? nil : input.speed,
                    volumeDb: nil, opacity: nil,
                    fadeInFrames: nil, fadeOutFrames: nil,
                    fadeInInterpolation: nil, fadeOutInterpolation: nil,
                    edgeRounding: nil, edgeSoftness: nil, transform: nil, crop: nil,
                    blendMode: nil, setBlendMode: false, audioMix: nil, duckingRole: nil,
                    clipId: partnerId,
                    editor: editor
                )
            }
        }
        let changed = beforeClips.contains { id, clip in editor.clipFor(id: id) != clip }
        return mutationResult(
            editor,
            since: snapshot,
            touched: clipIds + Array(partners),
            extra: ["changed": changed],
            notes: notes
        )
    }

    fileprivate static func applyPropertyChanges(
        durationFrames: Int?,
        trimStartFrame: Int?,
        trimEndFrame: Int?,
        speed: Double?,
        volumeDb: Double?,
        opacity: Double?,
        fadeInFrames: Int?,
        fadeOutFrames: Int?,
        fadeInInterpolation: Interpolation?,
        fadeOutInterpolation: Interpolation?,
        edgeRounding: Double?,
        edgeSoftness: Double?,
        transform: ParsedTransform?,
        crop: Crop?,
        blendMode: BlendMode?,
        setBlendMode: Bool,
        audioMix: ParsedAudioMix?,
        duckingRole: DuckingRole?,
        clipId: String,
        editor: EditorViewModel
    ) -> [String] {
        var changed: [String] = []
        editor.commitClipProperty(clipId: clipId) { clip in
            changed.append(contentsOf: applyTimingChanges(
                durationFrames: durationFrames,
                trimStartFrame: trimStartFrame,
                trimEndFrame: trimEndFrame,
                speed: speed,
                to: &clip
            ))
            // Setting a scalar clears any existing keyframe track on the same property.
            if let v = volumeDb {
                clip.volume = VolumeScale.linearFromDb(v)
                clip.volumeTrack = nil
                changed.append("volumeDb")
            }
            if let v = opacity        { clip.opacity = v; clip.opacityTrack = nil; changed.append("opacity") }
            if let v = fadeInFrames   { clip.setFade(.left, frames: v); changed.append("fadeInFrames") }
            if let v = fadeOutFrames  { clip.setFade(.right, frames: v); changed.append("fadeOutFrames") }
            if let v = fadeInInterpolation {
                clip.setFadeInterpolation(.left, v)
                changed.append("fadeInInterpolation")
            }
            if let v = fadeOutInterpolation {
                clip.setFadeInterpolation(.right, v)
                changed.append("fadeOutInterpolation")
            }
            if let v = edgeRounding { clip.edgeRounding = v; changed.append("edgeRounding") }
            if let v = edgeSoftness { clip.edgeSoftness = v; changed.append("edgeSoftness") }
            if setBlendMode           { clip.blendMode = blendMode; changed.append("blendMode") }
            if let audioMix           { audioMix.apply(to: &clip); changed.append("audioMix") }
            if let duckingRole        { clip.duckingRole = duckingRole; changed.append("duckingRole") }
            if let t = transform {
                t.apply(to: &clip)
                changed.append("transform")
            }
            if let crop {
                clip.crop = crop
                clip.cropTrack = nil
                changed.append("crop")
            }
        }
        return changed
    }

    private static func applyTimingChanges(
        durationFrames: Int?,
        trimStartFrame: Int?,
        trimEndFrame: Int?,
        speed: Double?,
        to clip: inout Clip
    ) -> [String] {
        var changed: [String] = []
        if let v = durationFrames {
            clip.setDuration(v)
            changed.append("durationFrames")
        }
        if let v = trimStartFrame { clip.trimStartFrame = v; changed.append("trimStartFrame") }
        if let v = trimEndFrame   { clip.trimEndFrame   = v; changed.append("trimEndFrame") }
        if let v = speed {
            if !clip.supportsRetiming {
                changed.append("speed skipped (nested timelines don't support retiming)")
            } else if clip.hasSpeedRamp {
                changed.append("speed skipped (clip has a speed curve — clear it with set_keyframes first)")
            } else {
                if durationFrames == nil, v > 0 {
                    let sourceConsumed = Double(clip.durationFrames) * clip.speed
                    clip.setDuration(max(1, safeInt((sourceConsumed / v).rounded()) ?? clip.durationFrames))
                    changed.append("durationFrames")
                }
                clip.speed = v
                changed.append("speed")
            }
        }
        return changed
    }

    private static func fadeInterpolation(_ rawValue: String?, field: String) throws -> Interpolation? {
        guard let rawValue else { return nil }
        guard let value = Interpolation(rawValue: rawValue), value == .linear || value == .smooth else {
            throw ToolError("\(field) must be 'linear' or 'smooth' (got '\(rawValue)')")
        }
        return value
    }

    // MARK: copy_clip_settings

    func copyClipSettings(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        if let rawTargetTrack = args["targetTrack"] {
            guard let targetTrack = rawTargetTrack as? [String: Any] else {
                throw ToolError("copy_clip_settings.targetTrack: expected object")
            }
            try validateUnknownKeys(
                targetTrack,
                allowed: ["trackId", "range"],
                path: "copy_clip_settings.targetTrack"
            )
        }
        let input: CopyClipSettingsInput = try decodeToolArgs(args, path: "copy_clip_settings")
        guard (input.targetClipIds != nil) != (input.targetTrack != nil) else {
            throw ToolError("Provide exactly one of 'targetClipIds' or 'targetTrack'")
        }

        let settings = try editor.clipSettingsSnapshot(for: input.sourceClipId)

        var targetSelection: [String: Any]?
        var incompatibleClipCount = 0
        var sourceExcluded = false
        let targetClipIds: [String]
        if let explicitIds = input.targetClipIds {
            var seen = Set<String>()
            targetClipIds = explicitIds.filter { seen.insert($0).inserted }
            guard !targetClipIds.isEmpty else {
                throw ToolError("Provide a non-empty 'targetClipIds' array")
            }
        } else {
            guard let targetTrack = input.targetTrack else {
                throw ToolError("Provide exactly one of 'targetClipIds' or 'targetTrack'")
            }
            guard let track = editor.timeline.tracks.first(where: { $0.id == targetTrack.trackId }) else {
                throw ToolError("Track not found: \(targetTrack.trackId)")
            }
            let range: Range<Int>?
            if let frames = targetTrack.range {
                guard frames.count == 2, frames[0] >= 0, frames[1] > frames[0] else {
                    throw ToolError("targetTrack.range must be [startFrame, endFrame) with 0 <= startFrame < endFrame")
                }
                range = frames[0]..<frames[1]
            } else {
                range = nil
            }
            let scopedClips = track.clips.filter { clip in
                range.map { clip.startFrame < $0.upperBound && clip.endFrame > $0.lowerBound } ?? true
            }
            targetClipIds = scopedClips.compactMap {
                $0.id != input.sourceClipId && $0.mediaType == settings.mediaType ? $0.id : nil
            }
            sourceExcluded = scopedClips.contains { $0.id == input.sourceClipId }
            incompatibleClipCount = scopedClips.count {
                $0.id != input.sourceClipId && $0.mediaType != settings.mediaType
            }
            guard !targetClipIds.isEmpty else {
                throw ToolError("No \(settings.mediaType.rawValue) clips matched targetTrack \(targetTrack.trackId)")
            }
            var selection: [String: Any] = ["trackId": targetTrack.trackId]
            if let frames = targetTrack.range { selection["range"] = frames }
            targetSelection = selection
        }

        let snapshot = timelineSnapshot(editor)
        let transfer = try editor.applyClipSettings(
            settings,
            to: targetClipIds,
            actionName: "Copy Clip Settings (Agent)"
        )

        var extra: [String: Any] = [
            "changed": !transfer.changedClipIds.isEmpty,
            "sourceClipId": input.sourceClipId,
            "mediaType": settings.mediaType.rawValue,
        ]
        if let targetSelection {
            extra["targetTrack"] = targetSelection
            extra["matchedClipCount"] = targetClipIds.count
            extra["changedClipCount"] = transfer.changedClipIds.count
            extra["unchangedClipCount"] = transfer.unchangedClipIds.count
            extra["incompatibleClipCount"] = incompatibleClipCount
            extra["sourceExcluded"] = sourceExcluded
        } else {
            extra["targetClipIds"] = targetClipIds
            extra["changedClipIds"] = transfer.changedClipIds
            extra["unchangedClipIds"] = transfer.unchangedClipIds
        }
        return mutationResult(
            editor,
            since: snapshot,
            touched: targetSelection == nil ? transfer.changedClipIds : [],
            extra: extra
        )
    }

    // MARK: set_keyframes

    private static let keyframePropertyNames: Set<String> = ["volumeDb", "opacity", "rotation", "position", "scale", "crop", "speed", "blur"]

    func setKeyframes(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SetKeyframesInput = try decodeToolArgs(args, path: "set_keyframes")

        let clipIds = input.clipIds ?? input.clipId.map { [$0] } ?? []
        guard !clipIds.isEmpty else { throw ToolError("Provide 'clipId' or a non-empty 'clipIds'.") }
        guard Set(clipIds).count == clipIds.count else { throw ToolError("clipIds contains duplicates.") }
        var resolvedIds: [String: String] = [:]
        for id in clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            resolvedIds[clip.id] = id
        }

        let mode = input.mode ?? "replace"
        guard mode == "replace" || mode == "merge" else {
            throw ToolError("mode must be 'replace' or 'merge' (got '\(mode)')")
        }
        let merge = mode == "merge"
        let stagger = input.stagger ?? 0
        if stagger != 0, clipIds.count < 2 {
            throw ToolError("stagger needs 'clipIds' with at least 2 clips.")
        }

        var requested: [(property: String, path: String, rows: [Any])] = []
        if let rawTracks = args["tracks"] {
            guard args["property"] == nil, args["keyframes"] == nil else {
                throw ToolError("Use either 'tracks' or 'property'+'keyframes', not both.")
            }
            guard let dict = rawTracks as? [String: Any], !dict.isEmpty else {
                throw ToolError("'tracks' must be a non-empty object mapping a property name to its keyframe rows.")
            }
            for (property, rawRows) in dict.sorted(by: { $0.key < $1.key }) {
                guard let rows = rawRows as? [Any] else {
                    throw ToolError("tracks.\(property): expected an array of keyframe rows")
                }
                requested.append((property, "tracks.\(property)", rows))
            }
        } else {
            guard let property = input.property else {
                throw ToolError("Missing required field 'property' (or pass 'tracks' to set several properties at once)")
            }
            guard let rows = args["keyframes"] as? [Any] else {
                throw ToolError("Missing required field 'keyframes' (must be an array)")
            }
            requested.append((property, "keyframes", rows))
        }

        if merge, let empty = requested.first(where: { $0.rows.isEmpty }) {
            throw ToolError("\(empty.path): empty rows with mode 'merge' change nothing — use mode 'replace' to clear a track.")
        }

        let repeatSpec = try Self.parseRepeatSpec(args["repeat"])
        if repeatSpec != nil {
            guard !merge else { throw ToolError("repeat requires mode 'replace' — it bakes a full track.") }
            if let empty = requested.first(where: { $0.rows.isEmpty }) {
                throw ToolError("\(empty.path): repeat needs keyframe rows to unroll.")
            }
        }

        if requested.contains(where: { $0.property == "blur" }) {
            for id in clipIds {
                guard editor.clipFor(id: id)?.supportsKeyframes(for: .blur) == true else {
                    throw ToolError("Clip \(id) does not support blur keyframes.")
                }
            }
        }

        let writers = try requested.map {
            try Self.keyframeWriter(property: $0.property, path: $0.path, rows: $0.rows, merge: merge, repeatSpec: repeatSpec)
        }
        let offsets = Dictionary(uniqueKeysWithValues: clipIds.enumerated().map { ($1, stagger * $0) })

        var rampNotes: [String] = []
        if requested.contains(where: { $0.property == "speed" }) {
            rampNotes = try Self.validateSpeedCurves(editor, clipIds: clipIds, offsets: offsets, writers: writers)
        }

        let snapshot = timelineSnapshot(editor)
        editor.undo.perform("Set Keyframes (Agent)") {
            editor.commitClipProperties(clipIds: clipIds, actionName: "Set Keyframes (Agent)") { clip in
                let offset = resolvedIds[clip.id].flatMap { offsets[$0] } ?? 0
                for write in writers { write(&clip, offset) }
            }
        }

        var notes = rampNotes
        let cleared = requested.filter { $0.rows.isEmpty }.map(\.property)
        if !cleared.isEmpty { notes.append("Cleared \(cleared.joined(separator: ", ")) keyframes.") }
        if stagger != 0 { notes.append("Staggered by \(stagger) frames per clip in clipIds order.") }
        if let repeatSpec {
            notes.append("Unrolled \(repeatSpec.count) \(repeatSpec.pingPong ? "ping-pong" : "loop") cycles into explicit keyframes.")
        }
        return mutationResult(editor, since: snapshot, touched: clipIds, notes: notes)
    }

    private static func validateSpeedCurves(
        _ editor: EditorViewModel,
        clipIds: [String],
        offsets: [String: Int],
        writers: [(inout Clip, Int) -> Void]
    ) throws -> [String] {
        var notes: [String] = []
        for id in clipIds {
            guard var candidate = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            let resolvedId = candidate.id
            let before = candidate.hasSpeedRamp
            for write in writers { write(&candidate, offsets[id] ?? 0) }
            do {
                try candidate.validateSpeedRamp(candidate.speedTrack)
            } catch {
                throw ToolError(error.message)
            }
            if let track = editor.timeline.tracks.first(where: { $0.clips.contains { $0.id == resolvedId } }),
               let transition = track.transitionTouching(clipId: resolvedId),
               candidate.hasSpeedRamp {
                throw ToolError(
                    SpeedRampRefusal.transitionOnEdge(clipId: resolvedId, transitionId: transition.id).message
                )
            }
            if let ramp = candidate.speedRamp {
                notes.append(
                    "Clip \(id): speed curve plays \(ramp.sourceFramesConsumed) source frames across "
                    + "\(candidate.durationFrames) timeline frames (\(ramp.segments.count) constant-rate segments); "
                    + "\(candidate.rampSourceBudgetFrames - ramp.sourceFramesConsumed) source frames spare."
                )
            } else if before {
                notes.append("Clip \(id): speed curve cleared; the clip is back to constant speed \(candidate.speed).")
            }
        }
        return notes
    }

    private static func parseRepeatSpec(_ raw: Any?) throws -> KeyframeRepeatSpec? {
        guard let raw else { return nil }
        guard let obj = raw as? [String: Any] else {
            throw ToolError("repeat: expected {count, type, gapFrames?}")
        }
        try validateKeys(obj, allowed: ["count", "type", "gapFrames"], at: "repeat")
        guard let rawCount = obj["count"] else { throw ToolError("repeat.count is required") }
        let count = try kfInt(rawCount, at: "repeat.count")
        guard (2...50).contains(count) else {
            throw ToolError("repeat.count: must be between 2 and 50 (got \(count))")
        }
        guard let type = obj["type"] as? String else {
            throw ToolError("repeat.type: expected 'loop', 'reverse', or 'mirror'")
        }
        guard ["loop", "reverse", "mirror"].contains(type) else {
            throw ToolError("repeat.type: expected 'loop', 'reverse', or 'mirror' (got '\(type)')")
        }
        let gap = try obj["gapFrames"].map { try kfInt($0, at: "repeat.gapFrames") } ?? 0
        guard gap >= 0, gap <= 10_000 else {
            throw ToolError("repeat.gapFrames: must be between 0 and 10000 (got \(gap))")
        }
        return KeyframeRepeatSpec(count: count, pingPong: type != "loop", gapFrames: gap)
    }

    static func unrollRepeat<V>(_ track: KeyframeTrack<V>, _ spec: KeyframeRepeatSpec, path: String) throws -> KeyframeTrack<V> {
        let kfs = track.keyframes
        guard kfs.count >= 2, let first = kfs.first?.frame, let last = kfs.last?.frame, last > first else {
            throw ToolError("\(path): repeat needs at least 2 keyframes spanning more than 0 frames.")
        }
        guard kfs.count * spec.count <= 600 else {
            throw ToolError("\(path): repeat would produce more than 600 keyframes (\(kfs.count) × \(spec.count)).")
        }
        let span = last - first
        var out = kfs
        for i in 1..<spec.count {
            let iteration: [Keyframe<V>]
            if spec.pingPong {
                let base = first + i * (span + spec.gapFrames)
                if i.isMultiple(of: 2) {
                    iteration = kfs.map { $0.retimed(to: base + ($0.frame - first)) }
                } else {
                    iteration = (0..<kfs.count).reversed().map { j in
                        let src = kfs[j]
                        // The outgoing easing of a reversed keyframe is the time-mirrored easing of the segment it now starts.
                        var kf = Keyframe(frame: base + (span - (src.frame - first)), value: src.value)
                        if let segment = j > 0 ? kfs[j - 1] : nil {
                            (kf.interpolationOut, kf.easingParams, kf.interpolationIn, kf.easingParamsIn) =
                                Self.reversedSegmentEasing(segment)
                        }
                        return kf
                    }
                }
            } else {
                let base = i * (span + max(spec.gapFrames, 1))
                iteration = kfs.map { $0.retimed(to: $0.frame + base) }
            }
            for kf in iteration {
                if kf.frame == out.last?.frame { out[out.count - 1] = kf } else { out.append(kf) }
            }
        }
        return KeyframeTrack(keyframes: out)
    }

    /// A time-reversed split-ease segment swaps depart and arrival curves, each mirrored.
    private static func reversedSegmentEasing<V>(
        _ seg: Keyframe<V>
    ) -> (Interpolation, [Double]?, Interpolation?, [Double]?) {
        guard let arrive = seg.interpolationIn else {
            return (seg.interpolationOut.mirrored, mirroredEasingParams(seg.interpolationOut, seg.easingParams), nil, nil)
        }
        return (
            arrive.mirrored, mirroredEasingParams(arrive, seg.easingParamsIn),
            seg.interpolationOut.mirrored, mirroredEasingParams(seg.interpolationOut, seg.easingParams)
        )
    }

    private static func mirroredEasingParams(_ interp: Interpolation, _ params: [Double]?) -> [Double]? {
        guard let p = params else { return nil }
        if interp == .cubicBezier, p.count == 4 {
            return [1 - p[2], 1 - p[3], 1 - p[0], 1 - p[1]]
        }
        return p
    }

    private static func keyframeWriter(property: String, path: String, rows: [Any], merge: Bool, repeatSpec: KeyframeRepeatSpec?) throws -> (inout Clip, Int) -> Void {
        func writer<V>(
            _ parsed: KeyframeTrack<V>,
            _ keyPath: WritableKeyPath<Clip, KeyframeTrack<V>?>
        ) throws -> (inout Clip, Int) -> Void {
            let kfs = try repeatSpec.map { try Self.unrollRepeat(parsed, $0, path: path) } ?? parsed
            return { clip, offset in
                let shifted = offset == 0 ? kfs.keyframes : kfs.keyframes.map { $0.retimed(to: $0.frame + offset) }
                if merge {
                    var track = clip[keyPath: keyPath] ?? KeyframeTrack<V>()
                    for kf in shifted { track.upsert(kf) }
                    clip[keyPath: keyPath] = track.keyframes.isEmpty ? nil : track
                } else {
                    clip[keyPath: keyPath] = shifted.isEmpty ? nil : KeyframeTrack(keyframes: shifted)
                }
            }
        }
        switch property {
        case "volumeDb":
            let kfs = try parseScalarKeyframes(
                rows,
                path: path,
                valueName: "decibels",
                range: VolumeScale.floorDb...VolumeScale.ceilingDb
            )
            return try writer(kfs, \.volumeTrack)
        case "opacity":
            return try writer(try parseScalarKeyframes(rows, path: path, range: 0...1), \.opacityTrack)
        case "rotation":
            return try writer(try parseScalarKeyframes(rows, path: path), \.rotationTrack)
        case "position":
            return try writer(try parsePairKeyframes(rows, path: path), \.positionTrack)
        case "scale":
            return try writer(try parsePairKeyframes(rows, path: path), \.scaleTrack)
        case "crop":
            return try writer(try parseCropKeyframes(rows, path: path), \.cropTrack)
        case "speed":
            let kfs = try parseScalarKeyframes(
                rows, path: path, valueName: "multiplier", range: SpeedRamp.multiplierRange
            )
            return try writer(kfs, \.speedTrack)
        case "blur":
            let parsed = try parseScalarKeyframes(rows, path: path, range: 0...100)
            let kfs = try repeatSpec.map { try Self.unrollRepeat(parsed, $0, path: path) } ?? parsed
            return { clip, offset in
                let shifted = offset == 0 ? kfs.keyframes : kfs.keyframes.map { $0.retimed(to: $0.frame + offset) }
                if merge {
                    var track = clip.blurKeyframeTrack ?? KeyframeTrack<Double>()
                    for kf in shifted { track.upsert(kf) }
                    clip.setBlurKeyframeTrack(track.keyframes.isEmpty ? nil : track)
                } else {
                    clip.setBlurKeyframeTrack(shifted.isEmpty ? nil : KeyframeTrack(keyframes: shifted))
                }
            }
        default:
            throw ToolError("Unknown property '\(property)'. Expected one of: \(keyframePropertyNames.sorted().joined(separator: ", "))")
        }
    }

    // MARK: split_clips

    func splitClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SplitClipsInput = try decodeToolArgs(args, path: "split_clips")
        let hasSplits = !(input.splits ?? []).isEmpty
        let hasTrack = input.trackIndex != nil || !(input.frames ?? []).isEmpty
        guard hasSplits != hasTrack else {
            throw ToolError("Provide exactly one of 'splits' (an array of {clipId, atFrame}) or 'trackIndex'+'frames' (project frames to cut on one track).")
        }

        // Resolve every cut to a (trackIndex, atFrame) pair against the CURRENT timeline
        var points: [(trackIndex: Int, atFrame: Int)] = []
        var seen: Set<String> = []

        func addCut(trackIndex: Int, atFrame: Int, clip: Clip) throws {
            guard atFrame > clip.startFrame && atFrame < clip.endFrame else {
                throw ToolError("Frame \(atFrame) is outside clip \(clip.id) range (\(clip.startFrame)..\(clip.endFrame))")
            }
            let key = "\(trackIndex):\(atFrame)"
            guard seen.insert(key).inserted else { return }
            points.append((trackIndex, atFrame))
        }

        if hasSplits {
            for s in input.splits ?? [] {
                guard let loc = editor.findClip(id: s.clipId) else { throw ToolError("Clip not found: \(s.clipId)") }
                let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
                try addCut(trackIndex: loc.trackIndex, atFrame: s.atFrame, clip: clip)
            }
        } else {
            guard let trackIndex = input.trackIndex,
                  trackIndex >= 0, trackIndex < editor.timeline.tracks.count else {
                throw ToolError("trackIndex is required and must be in 0..\(editor.timeline.tracks.count - 1)")
            }
            guard let frames = input.frames, !frames.isEmpty else {
                throw ToolError("'frames' must be a non-empty array of project frames")
            }
            let track = editor.timeline.tracks[trackIndex]
            for f in frames {
                guard let clip = track.clips.first(where: { f > $0.startFrame && f < $0.endFrame }) else {
                    throw ToolError("Frame \(f) is not strictly inside any clip on track \(trackIndex)")
                }
                try addCut(trackIndex: trackIndex, atFrame: f, clip: clip)
            }
        }

        guard !points.isEmpty else { throw ToolError("No valid split points") }
        let snapshot = timelineSnapshot(editor)
        editor.undo.perform(points.count == 1 ? "Split Clip (Agent)" : "Split Clips (Agent)") {
            _ = editor.splitClips(at: points)
        }
        return mutationResult(editor, since: snapshot)
    }

    // MARK: ripple_delete_ranges

    func rippleDeleteRanges(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: RippleDeleteRangesInput = try decodeToolArgs(args, path: "ripple_delete_ranges")
        guard !input.ranges.isEmpty else { throw ToolError("Missing or empty 'ranges' array") }
        let units = input.units ?? "frames"
        guard units == "seconds" || units == "frames" else {
            throw ToolError("units must be 'seconds' or 'frames' (got '\(units)')")
        }
        guard (input.clipId != nil) != (input.trackIndex != nil) else {
            throw ToolError("Provide exactly one of 'clipId' (cut within a single clip; allows 'seconds') or 'trackIndex' (cut project-frame ranges spanning a whole track in one call).")
        }
        let fps = editor.timeline.fps

        for (i, r) in input.ranges.enumerated() {
            guard r.count == 2 else {
                throw ToolError("ranges[\(i)]: expected [start, end] (got \(r.count) element\(r.count == 1 ? "" : "s"))")
            }
            guard r[1] > r[0] else {
                throw ToolError("ranges[\(i)]: end (\(r[1])) must be greater than start (\(r[0]))")
            }
        }

        var frameRanges: [FrameRange] = []
        var dropped = 0
        let resolvedTrackIndex: Int

        if let clipId = input.clipId {
            guard let loc = editor.findClip(id: clipId) else { throw ToolError("Clip not found: \(clipId)") }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            // 'frames' are project frames as-is; 'seconds' are source seconds → map through trim/speed/position.
            func toFrame(_ v: Double) -> Double {
                units == "frames"
                    ? v
                    : Double(clip.startFrame) + (v * Double(fps) - Double(clip.trimStartFrame)) / max(clip.speed, 0.0001)
            }
            for r in input.ranges {
                let s = clampInt(toFrame(r[0]), min: clip.startFrame, max: clip.endFrame)
                let e = clampInt(toFrame(r[1]), min: clip.startFrame, max: clip.endFrame)
                if e > s { frameRanges.append(FrameRange(start: s, end: e)) } else { dropped += 1 }
            }
            guard !frameRanges.isEmpty else {
                throw ToolError("No ranges fall within clip \(clipId) (frames \(clip.startFrame)..\(clip.endFrame)). In '\(units)' units, ranges must overlap the clip's visible span.")
            }
            resolvedTrackIndex = loc.trackIndex
        } else {
            let trackIndex = input.trackIndex!
            guard units == "frames" else {
                throw ToolError("units 'seconds' requires a clipId for source-media mapping; with trackIndex, ranges are project frames.")
            }
            guard editor.timeline.tracks.indices.contains(trackIndex) else {
                throw ToolError("Track index out of range: \(trackIndex)")
            }
            for r in input.ranges {
                let s = clampInt(r[0], min: 0, max: editor.timeline.totalFrames)
                let e = clampInt(r[1], min: 0, max: editor.timeline.totalFrames)
                if e > s { frameRanges.append(FrameRange(start: s, end: e)) } else { dropped += 1 }
            }
            guard !frameRanges.isEmpty else {
                throw ToolError("No valid project-frame ranges to delete on track \(trackIndex).")
            }
            resolvedTrackIndex = trackIndex
        }

        let ignoreSyncLocked = Set(input.ignoreSyncLockedTracks ?? [])
        let snapshot = timelineSnapshot(editor)
        let outcome = editor.undo.perform("Ripple Delete (Agent)") {
            editor.rippleDeleteRangesOnTrack(trackIndex: resolvedTrackIndex, ranges: frameRanges, ignoreSyncLockTrackIndices: ignoreSyncLocked)
        }
        switch outcome {
        case .refused(let reason):
            throw ToolError(reason)
        case .ok(let report):
            var extra: [String: Any] = ["removedFrames": report.removedFrames]
            if dropped > 0 { extra["rangesIgnored"] = dropped }
            return mutationResult(
                editor, since: snapshot,
                touched: report.resultingFragments.map(\.clipId),
                extra: extra
            )
        }
    }

    // MARK: - Keyframe row parsing (shared by set_keyframes)

    /// Parse `[[frame, value0, value1, ..., interp?], ...]` into a keyframe track.
    private static func parseKeyframes<V>(
        _ rows: [Any],
        path: String,
        fieldNames: [String],
        validateValues: (Int, [Double]) throws -> Void = { _, _ in },
        build: ([Double]) -> V
    ) throws -> KeyframeTrack<V> {
        let arity = fieldNames.count
        let labels = fieldNames.joined(separator: ", ")
        let minLen = arity + 1
        let maxLen = arity + 2

        var out: [Keyframe<V>] = []
        for (i, raw) in rows.enumerated() {
            guard let row = raw as? [Any] else {
                throw ToolError("\(path)[\(i)]: expected array [frame, \(labels), interp?]")
            }
            guard row.count == minLen || row.count == maxLen else {
                throw ToolError("\(path)[\(i)]: expected [frame, \(labels)] or [frame, \(labels), interp] (got \(row.count) elements)")
            }
            let frame = try kfInt(row[0], at: "\(path)[\(i)][0] (frame)")
            let values = try (0..<arity).map { k in
                try kfDouble(row[k + 1], at: "\(path)[\(i)][\(k + 1)] (\(fieldNames[k]))")
            }
            try validateValues(i, values)
            let ease = try kfInterp(row.count > minLen ? row[minLen] : nil, at: "\(path)[\(i)][\(minLen)] (interp)")
            out.append(Keyframe(
                frame: frame, value: build(values),
                interpolationOut: ease.interp, easingParams: ease.params,
                interpolationIn: ease.interpIn, easingParamsIn: ease.paramsIn
            ))
        }
        return KeyframeTrack(keyframes: sortAndDedupe(out))
    }

    static func parseScalarKeyframes(
        _ rows: [Any],
        path: String,
        valueName: String = "value",
        range: ClosedRange<Double>? = nil
    ) throws -> KeyframeTrack<Double> {
        try parseKeyframes(
            rows,
            path: path,
            fieldNames: [valueName],
            validateValues: { index, values in
                guard let range, !range.contains(values[0]) else { return }
                throw ToolError(
                    "\(path)[\(index)][1] (\(valueName)): must be between \(range.lowerBound) and \(range.upperBound) (got \(values[0]))"
                )
            }
        ) {
            $0[0]
        }
    }

    fileprivate static func parsePairKeyframes(_ rows: [Any], path: String) throws -> KeyframeTrack<AnimPair> {
        try parseKeyframes(rows, path: path, fieldNames: ["a", "b"]) { AnimPair(a: $0[0], b: $0[1]) }
    }

    fileprivate static func parseCropKeyframes(_ rows: [Any], path: String) throws -> KeyframeTrack<Crop> {
        try parseKeyframes(rows, path: path, fieldNames: ["top", "right", "bottom", "left"]) {
            Crop(left: $0[3], top: $0[0], right: $0[1], bottom: $0[2])
        }
    }

    private static func sortAndDedupe<V>(_ kfs: [Keyframe<V>]) -> [Keyframe<V>] {
        let sorted = kfs.sorted { $0.frame < $1.frame }
        var out: [Keyframe<V>] = []
        out.reserveCapacity(sorted.count)
        for kf in sorted {
            if out.last?.frame == kf.frame { out[out.count - 1] = kf } else { out.append(kf) }
        }
        return out
    }

    private static func kfInt(_ raw: Any, at path: String) throws -> Int {
        guard !isJSONBoolean(raw) else { throw ToolError("\(path): expected integer") }
        if let v = raw as? Int { return v }
        if let v = raw as? Double, let i = safeInt(v) { return i }
        if let v = raw as? NSNumber, let i = safeInt(v.doubleValue) { return i }
        throw ToolError("\(path): expected integer")
    }

    private static func kfDouble(_ raw: Any, at path: String) throws -> Double {
        guard !isJSONBoolean(raw) else { throw ToolError("\(path): expected number") }
        let v: Double
        if let d = raw as? Double { v = d }
        else if let i = raw as? Int { v = Double(i) }
        else if let n = raw as? NSNumber { v = n.doubleValue }
        else { throw ToolError("\(path): expected number") }
        guard v.isFinite else {
            throw ToolError("\(path): value must be finite (got \(v))")
        }
        return v
    }

    struct ParsedEase {
        var interp: Interpolation = .smooth
        var params: [Double]? = nil
        var interpIn: Interpolation? = nil
        var paramsIn: [Double]? = nil
    }

    static func kfInterp(_ raw: Any?, at path: String) throws -> ParsedEase {
        guard let raw else { return ParsedEase() }
        if let obj = raw as? [String: Any], obj["type"] == nil {
            try validateKeys(obj, allowed: ["out", "in"], at: path)
            guard obj["out"] != nil || obj["in"] != nil else {
                throw ToolError("\(path): easing object needs a 'type', or 'out'/'in' curves for a split ease")
            }
            var ease = ParsedEase()
            if let out = obj["out"] {
                (ease.interp, ease.params) = try kfSimpleEase(out, at: "\(path).out")
            }
            if let arrive = obj["in"] {
                let (i, p) = try kfSimpleEase(arrive, at: "\(path).in")
                guard i != .hold else { throw ToolError("\(path).in: 'hold' is not a valid arrival ease") }
                (ease.interpIn, ease.paramsIn) = (i, p)
            }
            return ease
        }
        let (i, p) = try kfSimpleEase(raw, at: path)
        return ParsedEase(interp: i, params: p)
    }

    private static func kfSimpleEase(_ raw: Any, at path: String) throws -> (Interpolation, [Double]?) {
        if let s = raw as? String {
            guard let i = Interpolation(rawValue: s) else {
                let names = Interpolation.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", ")
                throw ToolError("\(path): expected one of \(names), a [x1,y1,x2,y2] bezier array, {type: 'spring'|'steps'|'cubicBezier'|'back'|'elastic', …}, or a split ease {out, in} (got '\(s)')")
            }
            return (i, nil)
        }
        if let arr = raw as? [Any] {
            return (.cubicBezier, try bezierPoints(arr, at: path))
        }
        if let obj = raw as? [String: Any] {
            guard let type = obj["type"] as? String else {
                throw ToolError("\(path): easing object needs a 'type' of 'spring', 'steps', 'cubicBezier', 'back', or 'elastic'")
            }
            switch type {
            case "spring":
                try validateKeys(obj, allowed: ["type", "bounce", "stiffness", "damping", "mass"], at: path)
                let bounce: Double
                if let raw = obj["bounce"] {
                    bounce = try kfDouble(raw, at: "\(path).bounce")
                    guard (0...1).contains(bounce) else {
                        throw ToolError("\(path).bounce: must be between 0 and 1 (got \(bounce))")
                    }
                } else if obj["stiffness"] != nil || obj["damping"] != nil || obj["mass"] != nil {
                    let stiffness = try obj["stiffness"].map { try kfDouble($0, at: "\(path).stiffness") } ?? 100
                    let damping = try obj["damping"].map { try kfDouble($0, at: "\(path).damping") } ?? 10
                    let mass = try obj["mass"].map { try kfDouble($0, at: "\(path).mass") } ?? 1
                    guard stiffness > 0, damping >= 0, mass > 0 else {
                        throw ToolError("\(path): spring needs stiffness > 0, damping >= 0, mass > 0")
                    }
                    let zeta = damping / (2 * (stiffness * mass).squareRoot())
                    bounce = min(1, max(0, 1 - zeta))
                } else {
                    bounce = 0.25
                }
                return (.spring, [bounce])
            case "steps":
                try validateKeys(obj, allowed: ["type", "count"], at: path)
                let count = try obj["count"].map { try kfInt($0, at: "\(path).count") } ?? 4
                guard (1...100).contains(count) else {
                    throw ToolError("\(path).count: must be between 1 and 100 (got \(count))")
                }
                return (.steps, [Double(count)])
            case "cubicBezier":
                try validateKeys(obj, allowed: ["type", "points"], at: path)
                guard let pts = obj["points"] as? [Any] else {
                    throw ToolError("\(path).points: expected [x1, y1, x2, y2]")
                }
                return (.cubicBezier, try bezierPoints(pts, at: "\(path).points"))
            case "back":
                try validateKeys(obj, allowed: ["type", "overshoot", "direction"], at: path)
                let overshoot = try obj["overshoot"].map { try kfDouble($0, at: "\(path).overshoot") }
                    ?? Interpolation.defaultBackOvershoot
                guard (0...10).contains(overshoot) else {
                    throw ToolError("\(path).overshoot: must be between 0 and 10 (got \(overshoot))")
                }
                let interp = try easeDirection(obj["direction"], at: path, in: .backIn, out: .backOut, inOut: .backInOut)
                return (interp, [overshoot])
            case "elastic":
                try validateKeys(obj, allowed: ["type", "amplitude", "period", "direction"], at: path)
                let amplitude = try obj["amplitude"].map { try kfDouble($0, at: "\(path).amplitude") } ?? 1
                guard (1...5).contains(amplitude) else {
                    throw ToolError("\(path).amplitude: must be between 1 and 5 (got \(amplitude))")
                }
                let interp = try easeDirection(obj["direction"], at: path, in: .elasticIn, out: .elasticOut, inOut: .elasticInOut)
                guard let rawPeriod = obj["period"] else { return (interp, [amplitude]) }
                let period = try kfDouble(rawPeriod, at: "\(path).period")
                guard (0.05...2).contains(period) else {
                    throw ToolError("\(path).period: must be between 0.05 and 2 (got \(period))")
                }
                return (interp, [amplitude, period])
            default:
                throw ToolError("\(path): unknown easing type '\(type)'. Expected 'spring', 'steps', 'cubicBezier', 'back', or 'elastic'.")
            }
        }
        throw ToolError("\(path): expected an easing name, a [x1,y1,x2,y2] bezier array, an easing object, or a split ease {out, in}")
    }

    private static func easeDirection(
        _ raw: Any?, at path: String,
        in inCase: Interpolation, out outCase: Interpolation, inOut: Interpolation
    ) throws -> Interpolation {
        guard let raw else { return outCase }
        guard let s = raw as? String, ["in", "out", "inOut"].contains(s) else {
            throw ToolError("\(path).direction: expected 'in', 'out', or 'inOut'")
        }
        return s == "in" ? inCase : s == "out" ? outCase : inOut
    }

    private static func bezierPoints(_ arr: [Any], at path: String) throws -> [Double] {
        guard arr.count == 4 else {
            throw ToolError("\(path): a cubic-bezier easing needs exactly 4 numbers [x1, y1, x2, y2] (got \(arr.count))")
        }
        let p = try arr.enumerated().map { try kfDouble($0.element, at: "\(path)[\($0.offset)]") }
        guard (0...1).contains(p[0]), (0...1).contains(p[2]) else {
            throw ToolError("\(path): bezier x1 and x2 must be within 0–1 (got \(p[0]), \(p[2]))")
        }
        return p
    }

    private static func validateKeys(_ obj: [String: Any], allowed: Set<String>, at path: String) throws {
        let unknown = Set(obj.keys).subtracting(allowed)
        guard unknown.isEmpty else {
            throw ToolError("\(path): unknown key\(unknown.count == 1 ? "" : "s") \(unknown.sorted().joined(separator: ", "))")
        }
    }

    // MARK: manage_tracks

    func manageTracks(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["reorder", "set", "remove"], path: "manage_tracks")
        let tracks = editor.timeline.tracks

        func trackId(_ index: Int, _ path: String) throws -> String {
            guard tracks.indices.contains(index) else {
                throw ToolError("\(path): track index \(index) out of range (timeline has \(tracks.count) tracks)")
            }
            return tracks[index].id
        }

        func trackId(_ entry: [String: Any], _ path: String) throws -> String {
            if let id = entry["trackId"] as? String {
                guard entry["index"] == nil, tracks.contains(where: { $0.id == id }) else {
                    throw ToolError("\(path): pass one current trackId or index")
                }
                return id
            }
            guard entry["trackId"] == nil, let index = exactJSONInt(entry["index"]) else {
                throw ToolError("\(path): pass one current trackId or index")
            }
            return try trackId(index, path)
        }

        var reorders: [(id: String, to: Int)] = []
        for (i, raw) in (args["reorder"] as? [Any] ?? []).enumerated() {
            guard let entry = raw as? [String: Any] else { throw ToolError("reorder[\(i)] must be an object") }
            let path = "reorder[\(i)]"
            try validateUnknownKeys(entry, allowed: ["trackId", "index", "to"], path: path)
            guard let to = exactJSONInt(entry["to"]) else {
                throw ToolError("\(path): 'to' is required and must be an integer")
            }
            let id = try trackId(entry, path)
            guard let from = tracks.firstIndex(where: { $0.id == id }),
                  tracks.indices.contains(to), tracks[from].type == tracks[to].type else {
                throw ToolError("\(path): destination index \(to) is outside the track's type zone")
            }
            reorders.append((id, to))
        }

        var updates: [(id: String, muted: Bool?, hidden: Bool?, syncLocked: Bool?, name: String?, includesName: Bool)] = []
        for (i, raw) in (args["set"] as? [Any] ?? []).enumerated() {
            guard let entry = raw as? [String: Any] else { throw ToolError("set[\(i)] must be an object") }
            let path = "set[\(i)]"
            try validateUnknownKeys(entry, allowed: ["trackId", "index", "muted", "hidden", "syncLocked", "name"], path: path)
            let muted = entry["muted"] as? Bool
            let hidden = entry["hidden"] as? Bool
            let syncLocked = entry["syncLocked"] as? Bool
            let includesName = entry.keys.contains("name")
            var name: String?
            if includesName {
                guard let rawName = entry["name"] as? String else {
                    throw ToolError("\(path).name must be a string")
                }
                do {
                    name = try TrackName.normalized(rawName)
                } catch {
                    throw ToolError("\(path).name must be one line of at most \(TrackName.maximumLength) characters")
                }
            }
            guard muted != nil || hidden != nil || syncLocked != nil || includesName else {
                throw ToolError("\(path): pass at least one of muted, hidden, syncLocked, name")
            }
            updates.append((try trackId(entry, path), muted, hidden, syncLocked, name, includesName))
        }

        var removeIds: [String] = []
        for (i, raw) in (args["remove"] as? [Any] ?? []).enumerated() {
            let path = "remove[\(i)]"
            if let entry = raw as? [String: Any] {
                try validateUnknownKeys(entry, allowed: ["trackId", "index"], path: path)
                removeIds.append(try trackId(entry, path))
                continue
            }
            guard let index = exactJSONInt(raw) else {
                throw ToolError("\(path) must be an integer index or track selector object")
            }
            removeIds.append(try trackId(index, path))
        }

        guard !reorders.isEmpty || !updates.isEmpty || !removeIds.isEmpty else {
            throw ToolError("Nothing to do — pass at least one of reorder, set, remove.")
        }

        let multicamTrackIds = Set(tracks.filter { t in
            t.clips.contains { $0.multicamGroupId != nil }
        }.map(\.id))
        if removeIds.contains(where: { multicamTrackIds.contains($0) }) {
            throw ToolError("A multicam group's track can't be removed — delete the group's clips first (remove_clips) and the empty track prunes itself.")
        }
        if updates.contains(where: { multicamTrackIds.contains($0.id) && $0.syncLocked == false }) {
            throw ToolError("Sync lock stays on for a multicam group's tracks — unlocking would let ripples shift the group's members apart.")
        }

        let snapshot = timelineSnapshot(editor)
        let removeIdSet = Set(removeIds)
        let removedTracks = tracks.indices.compactMap { i -> [String: Any]? in
            let track = tracks[i]
            guard removeIdSet.contains(track.id) else { return nil }
            return ["trackId": track.id, "index": i, "label": editor.timelineTrackDisplayLabel(at: i), "type": track.type.rawValue]
        }
        var reorderResults: [(trackId: String, from: Int, to: Int)] = []
        var renamedTracks: [[String: Any]] = []
        try editor.undo.perform("Manage Tracks (Agent)") {
            if !reorders.isEmpty {
                let before = editor.timeline
                for r in reorders {
                    guard let from = editor.timeline.tracks.firstIndex(where: { $0.id == r.id }) else { continue }
                    editor.reorderTrackLive(id: r.id, to: r.to)
                    let destination = editor.timeline.tracks.firstIndex(where: { $0.id == r.id }) ?? from
                    reorderResults.append((r.id, from, destination))
                }
                editor.commitTrackReorder(before: before)
            }
            for update in updates {
                guard let idx = editor.timeline.tracks.firstIndex(where: { $0.id == update.id }) else { continue }
                let track = editor.timeline.tracks[idx]
                if let muted = update.muted, track.muted != muted { editor.toggleTrackMute(trackIndex: idx) }
                if let hidden = update.hidden, track.hidden != hidden { editor.toggleTrackHidden(trackIndex: idx) }
                if let syncLocked = update.syncLocked, track.syncLocked != syncLocked {
                    editor.toggleTrackSyncLock(trackIndex: idx)
                }
                if update.includesName {
                    let changed = try editor.setTrackName(id: update.id, to: update.name)
                    renamedTracks.append([
                        "trackId": update.id,
                        "name": editor.timeline.tracks[idx].name ?? NSNull(),
                        "changed": changed,
                    ])
                }
            }
            if !removeIds.isEmpty { editor.removeTracks(ids: removeIds) }
        }

        let order = editor.timeline.tracks.indices.map { i -> [String: Any] in
            let track = editor.timeline.tracks[i]
            var entry: [String: Any] = [
                "trackId": track.id,
                "index": i,
                "label": editor.timelineTrackDisplayLabel(at: i),
                "type": track.type.rawValue,
            ]
            if let name = track.name { entry["name"] = name }
            if track.muted { entry["muted"] = true }
            if track.hidden { entry["hidden"] = true }
            if !track.syncLocked { entry["syncLocked"] = false }
            return entry
        }
        var extra: [String: Any] = ["tracks": order]
        if !reorderResults.isEmpty {
            extra["reordered"] = reorderResults.map { ["trackId": $0.trackId, "from": $0.from, "to": $0.to, "changed": $0.from != $0.to] }
        }
        if !renamedTracks.isEmpty { extra["renamed"] = renamedTracks }
        if !removedTracks.isEmpty { extra["removedTracks"] = removedTracks }
        return mutationResult(editor, since: snapshot, extra: extra)
    }
}
