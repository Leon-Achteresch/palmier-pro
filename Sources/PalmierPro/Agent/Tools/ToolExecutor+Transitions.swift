import Foundation

private struct AddTransitionInput: DecodableToolArgs {
    let fromClipId: String
    let toClipId: String
    let style: String
    let direction: String?
    let durationFrames: Int
    let alignment: String?
    static let allowedKeys: Set<String> = [
        "fromClipId", "toClipId", "style", "direction", "durationFrames", "alignment",
    ]
}

extension ToolExecutor {

    func addTransition(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: AddTransitionInput = try decodeToolArgs(args, path: "add_transition")
        guard let style = TransitionStyle(rawValue: input.style) else {
            throw ToolError("style must be one of \(TransitionStyle.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(input.style)')")
        }
        var direction: TransitionDirection?
        if let raw = input.direction {
            guard let parsed = TransitionDirection(rawValue: raw) else {
                throw ToolError("direction must be one of \(TransitionDirection.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(raw)')")
            }
            direction = parsed
        }
        guard style.requiresDirection || direction == nil else {
            throw ToolError(TransitionRefusal.unexpectedDirection(style).message)
        }
        var alignment = TransitionAlignment.centered
        if let raw = input.alignment {
            guard let parsed = TransitionAlignment(rawValue: raw) else {
                throw ToolError("alignment must be one of \(TransitionAlignment.allCases.map(\.rawValue).joined(separator: ", ")) (got '\(raw)')")
            }
            alignment = parsed
        }

        let snapshot = timelineSnapshot(editor)
        let resolved: ResolvedTransition
        do {
            resolved = try editor.addTransition(
                fromClipId: input.fromClipId,
                toClipId: input.toClipId,
                style: style,
                direction: direction,
                durationFrames: input.durationFrames,
                alignment: alignment
            )
        } catch {
            throw ToolError("\(error.code): \(error.message)")
        }
        guard let placed = editor.resolvedTransition(id: resolved.id) else {
            throw ToolError("internal_error: the transition did not stick to the timeline.")
        }
        return mutationResult(
            editor,
            since: snapshot,
            extra: ["transition": Self.transitionPayload(placed.resolved, trackIndex: placed.trackIndex)],
            notes: ["Clip start and end frames are unchanged — the transition plays out of each clip's handles."]
        )
    }

    static func transitionPayload(_ resolved: ResolvedTransition, trackIndex: Int? = nil) -> [String: Any] {
        var out: [String: Any] = [
            "transitionId": resolved.id,
            "style": resolved.transition.style.rawValue,
            "alignment": resolved.transition.alignment.rawValue,
            "durationFrames": resolved.window.durationFrames,
            "frames": [resolved.window.startFrame, resolved.window.endFrame],
            "cutFrame": resolved.window.cutFrame,
            "fromClipId": resolved.from.id,
            "toClipId": resolved.to.id,
        ]
        if let direction = resolved.transition.direction {
            out["direction"] = direction.rawValue
        }
        if let trackIndex {
            out["track"] = trackIndex
        }
        return out
    }
}
