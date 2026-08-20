import Foundation

fileprivate struct TrimClipsInput: DecodableToolArgs {
    let clipId: String
    let mode: String?
    let edge: String?
    let deltaFrames: Int
    let propagateToLinked: Bool?
    let scope: String?
    static let allowedKeys: Set<String> = ["clipId", "mode", "edge", "deltaFrames", "propagateToLinked", "scope"]
}

extension ToolExecutor {

    // MARK: trim_clips

    func trimClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: TrimClipsInput = try decodeToolArgs(args, path: "trim_clips")
        let mode = input.mode ?? "normal"
        guard ["normal", "ripple", "slip"].contains(mode) else {
            throw ToolError("mode must be 'normal', 'ripple', or 'slip' (got '\(mode)')")
        }
        guard input.deltaFrames != 0 else {
            throw ToolError("deltaFrames must not be 0.")
        }
        guard let clip = editor.clipFor(id: input.clipId) else {
            throw ToolError("Clip not found: \(input.clipId)")
        }
        let propagate = input.propagateToLinked ?? true
        let scopeRaw = input.scope ?? EditorViewModel.TrimScope.both.rawValue
        guard let scope = EditorViewModel.TrimScope(rawValue: scopeRaw) else {
            throw ToolError("scope must be 'both', 'videoOnly', or 'audioOnly' (got '\(scopeRaw)')")
        }

        var edge: EditorViewModel.TrimEdge = .right
        if mode == "slip" {
            guard input.edge == nil else {
                throw ToolError("'edge' does not apply to a slip — a slip moves both edges of the source range at once.")
            }
            guard editor.isSlipEligible(clip) else {
                throw ToolError("Clip \(input.clipId) can't slip: image, text, and multicam clips have no independent source range.")
            }
        } else {
            switch input.edge {
            case "left": edge = .left
            case "right": edge = .right
            case nil: throw ToolError("'edge' is required for a \(mode) trim ('left' or 'right').")
            case let other?: throw ToolError("edge must be 'left' or 'right' (got '\(other)')")
            }
            let durationDelta = edge == .right ? input.deltaFrames : -input.deltaFrames
            guard clip.durationFrames + durationDelta >= 1 else {
                throw ToolError("That trim would leave clip \(input.clipId) \(clip.durationFrames + durationDelta) frames long; a clip must keep at least 1 frame.")
            }
            if clip.multicamGroupId != nil {
                throw ToolError("Clip \(input.clipId) is a multicam clip — trimming it would slip the group out of sync. Use split_clips or change_cam instead.")
            }
        }

        if scope != .both {
            guard mode == "normal" else {
                throw ToolError("scope '\(scopeRaw)' applies only to a normal trim — ripple and slip always move both lanes.")
            }
            if let refusal = editor.trimRefusal(clipId: input.clipId, edge: edge, deltaFrames: input.deltaFrames, scope: scope) {
                throw ToolError(refusal)
            }
        }

        let targetIds: [String] = scope == .both
            ? [input.clipId]
            : editor.trimTargets(clipId: input.clipId, scope: scope, propagateToLinked: true).map(\.id)
        let before = targetIds.map { Self.trimState(editor, clipId: $0) }
        let snapshot = timelineSnapshot(editor)
        let actionName = "Trim Clip (Agent)"
        editor.undo.perform(actionName) {
            switch mode {
            case "ripple":
                editor.rippleTrimClip(clipId: input.clipId, edge: edge, deltaFrames: input.deltaFrames, propagateToLinked: propagate)
            case "slip":
                editor.commitSlip(clipId: input.clipId, deltaFrames: input.deltaFrames, propagateToLinked: propagate)
            default:
                editor.commitTrim(clipId: input.clipId, edge: edge, deltaFrames: input.deltaFrames, propagateToLinked: propagate, scope: scope)
            }
        }
        let after = targetIds.map { Self.trimState(editor, clipId: $0) }

        guard before != after else {
            return .ok(Self.jsonString([
                "status": "noop",
                "reason": "Nothing moved — the clip is already at the end of its source material, or a sync-locked track blocked the edit.",
                "clipId": input.clipId,
            ]) ?? "{}")
        }

        var notes: [String] = []
        let leadBefore = before[0]
        let leadAfter = after[0]
        let appliedDelta = mode == "slip"
            ? leadBefore.trimStart - leadAfter.trimStart
            : (edge == .right ? leadAfter.duration - leadBefore.duration : leadBefore.duration - leadAfter.duration)
        if mode != "slip", abs(leadAfter.duration - leadBefore.duration) != abs(input.deltaFrames) {
            notes.append("Clamped: asked for \(input.deltaFrames) frames, applied \(appliedDelta) — limited by source material, clip length, or a sync-locked track.")
        }
        if mode == "slip", appliedDelta != input.deltaFrames {
            notes.append("Clamped: asked to slip \(input.deltaFrames) frames, applied \(appliedDelta) — limited by the remaining head/tail material.")
        }
        if scope != .both {
            notes.append("Scoped trim: only the \(scope.lane) side moved; the link stays intact.")
        }
        return mutationResult(editor, since: snapshot, touched: targetIds, notes: notes)
    }

    private struct TrimState: Equatable {
        let start: Int
        let duration: Int
        let trimStart: Int
        let trimEnd: Int
    }

    private static func trimState(_ editor: EditorViewModel, clipId: String) -> TrimState {
        guard let clip = editor.clipFor(id: clipId) else { return TrimState(start: 0, duration: 0, trimStart: 0, trimEnd: 0) }
        return TrimState(start: clip.startFrame, duration: clip.durationFrames, trimStart: clip.trimStartFrame, trimEnd: clip.trimEndFrame)
    }
}
