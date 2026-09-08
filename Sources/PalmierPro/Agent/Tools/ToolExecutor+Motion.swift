import Foundation

extension ToolExecutor {
    fileprivate struct ApplyMotionInput: DecodableToolArgs {
        let clipId: String?
        let clipIds: [String]?
        let preset: String
        let intensity: Double?
        let durationSeconds: Double?
        let focusX: Double?
        let focusY: Double?
        let stagger: Int?
        static let allowedKeys: Set<String> = [
            "clipId", "clipIds", "preset", "intensity", "durationSeconds", "focusX", "focusY", "stagger",
        ]
    }

    func applyMotion(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ApplyMotionInput = try decodeToolArgs(args, path: "apply_motion")

        guard let preset = MotionPreset(rawValue: input.preset) else {
            let available = MotionPreset.allCases.map(\.rawValue).joined(separator: ", ")
            throw ToolError("Unknown preset '\(input.preset)'. Available: \(available).")
        }

        let clipIds = input.clipIds ?? input.clipId.map { [$0] } ?? []
        guard !clipIds.isEmpty else { throw ToolError("Provide 'clipId' or a non-empty 'clipIds'.") }
        guard Set(clipIds).count == clipIds.count else { throw ToolError("clipIds contains duplicates.") }

        let intensity = input.intensity ?? 50
        guard intensity.isFinite, (0...100).contains(intensity) else {
            throw ToolError("intensity must be between 0 and 100 (got \(intensity)).")
        }

        let seconds = input.durationSeconds ?? preset.defaultDurationSeconds
        if preset.category != .emphasis {
            guard seconds.isFinite, seconds > 0, seconds <= 30 else {
                throw ToolError("durationSeconds must be between 0 and 30 (got \(seconds)).")
            }
        }

        if input.focusX != nil || input.focusY != nil {
            guard preset == .punchIn else {
                throw ToolError("focusX/focusY only apply to the 'punch-in' preset.")
            }
            for (name, value) in [("focusX", input.focusX), ("focusY", input.focusY)] {
                if let value {
                    guard value.isFinite, (0...1).contains(value) else {
                        throw ToolError("\(name) must be between 0 and 1 (got \(value)).")
                    }
                }
            }
        }

        let stagger = input.stagger ?? 0
        if stagger != 0 {
            guard clipIds.count >= 2 else { throw ToolError("stagger needs 'clipIds' with at least 2 clips.") }
            guard preset.category != .emphasis else {
                throw ToolError("stagger does not apply to emphasis presets — they span each clip.")
            }
            guard (0...10_000).contains(stagger) else {
                throw ToolError("stagger must be between 0 and 10000 frames (got \(stagger)).")
            }
        }

        for id in clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            for property in preset.affectedProperties where !clip.supportsKeyframes(for: property) {
                throw ToolError("Clip \(id) does not support \(property.rawValue) keyframes required by '\(preset.rawValue)'.")
            }
        }

        let rampFrames = max(Int((seconds * Double(editor.timeline.fps)).rounded()), 1)
        let snapshot = timelineSnapshot(editor)
        let receipts = editor.applyMotionPreset(
            preset,
            intensity: intensity / 100,
            rampFrames: rampFrames,
            focusX: input.focusX,
            focusY: input.focusY,
            staggerFrames: stagger,
            to: clipIds
        )

        var notes: [String] = []
        for id in clipIds {
            guard let clip = editor.clipFor(id: id), let receipt = receipts[clip.id] else { continue }
            let properties = receipt.properties.map(\.rawValue).joined(separator: ", ")
            notes.append(
                "Clip \(id): \(receipt.keyframeCount) poses on [\(properties)] over clip-relative frames "
                + "\(receipt.segment.lowerBound)–\(receipt.segment.upperBound); keyframes are editable via set_keyframes."
            )
        }
        if stagger != 0 { notes.append("Staggered by \(stagger) frames per clip in clipIds order.") }
        return mutationResult(editor, since: snapshot, touched: clipIds, notes: notes)
    }
}
