import Foundation

extension ToolExecutor {
    private static let managePresetsKeys: Set<String> = [
        "action", "kind", "presetId", "name", "sourceClipId", "clipIds",
    ]

    func managePresets(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.managePresetsKeys, path: "manage_presets")
        let action = try args.requireString("action")
        let store = presetStore
        await store.ensureLoaded()

        switch action {
        case "list":
            let kinds = try args.string("kind").map { [try Self.presetKind($0)] } ?? PresetKind.allCases
            let presets = kinds.flatMap { store.library(kind: $0) }
            return try Self.okJSON([
                "count": presets.count,
                "presets": presets.map { Self.presetPayload($0) },
            ])

        case "save":
            let kind = try Self.presetKind(try args.requireString("kind"))
            let sourceClipId = try args.requireString("sourceClipId")
            guard let clip = editor.clipFor(id: sourceClipId) else {
                throw ToolError("Clip not found: \(sourceClipId)")
            }
            guard kind.supports(clip) else {
                throw ToolError("manage_presets: kind '\(kind.rawValue)' needs \(Self.expectedClipDescription(kind)); clip \(sourceClipId) is \(clip.mediaType.rawValue).")
            }
            guard let payload = kind.payload(from: clip) else {
                throw ToolError("Clip \(sourceClipId) carries no \(kind.rawValue) to save. \(Self.captureHint(kind))")
            }
            let requested = (args.string("name") ?? Self.defaultName(kind: kind, clip: clip))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !requested.isEmpty else { throw ToolError("manage_presets: name is empty.") }
            let preset = try await store.save(name: requested, kind: kind, payload: payload)
            var out = Self.presetPayload(preset)
            out["savedFromClipId"] = sourceClipId
            if preset.name != requested {
                out["notes"] = ["A preset named '\(requested)' already existed; saved as '\(preset.name)'."]
            }
            return try Self.okJSON(out)

        case "apply":
            let presetId = try args.requireString("presetId")
            let preset = try Self.requirePreset(presetId, in: store)
            let clipIds = args.stringArray("clipIds")
            guard !clipIds.isEmpty else { throw ToolError("manage_presets: apply needs clipIds.") }
            for id in clipIds {
                guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
                guard preset.kind.supports(clip) else {
                    throw ToolError("Preset '\(preset.name)' is a \(preset.kind.rawValue) preset and needs \(Self.expectedClipDescription(preset.kind)); clip \(id) is \(clip.mediaType.rawValue).")
                }
            }
            let snapshot = timelineSnapshot(editor)
            let actionName = "\(PresetApplication.actionName(for: preset)) (Agent)"
            let applied = PresetApplication.apply(preset, to: clipIds, editor: editor, actionName: actionName)
            guard !applied.isEmpty else {
                return try Self.okJSON(["status": "noop", "reason": "No target clips left to apply '\(preset.name)' to."])
            }
            return mutationResult(
                editor,
                since: snapshot,
                touched: applied,
                extra: ["preset": Self.presetPayload(preset)]
            )

        case "rename":
            let presetId = try args.requireString("presetId")
            let name = try args.requireString("name")
            let existing = try Self.requirePreset(presetId, in: store)
            try Self.requireEditable(existing)
            let preset = try await store.rename(id: presetId, to: name)
            var out = Self.presetPayload(preset)
            if preset.name != name.trimmingCharacters(in: .whitespacesAndNewlines) {
                out["notes"] = ["A preset named '\(name)' already existed; renamed to '\(preset.name)'."]
            }
            return try Self.okJSON(out)

        case "delete":
            let presetId = try args.requireString("presetId")
            let existing = try Self.requirePreset(presetId, in: store)
            try Self.requireEditable(existing)
            let preset = try await store.delete(id: presetId)
            return try Self.okJSON(["deleted": Self.presetPayload(preset)])

        default:
            throw ToolError("manage_presets: unknown action '\(action)'. Use list, save, apply, rename, or delete.")
        }
    }

    static func presetPayload(_ preset: StylePreset) -> [String: Any] {
        var out: [String: Any] = [
            "presetId": preset.id,
            "name": preset.name,
            "kind": preset.kind.rawValue,
        ]
        if preset.isBuiltIn {
            out["builtIn"] = true
        } else {
            out["createdAt"] = preset.createdAt.formatted(.iso8601)
        }
        switch preset.payload {
        case .effects(let stack):
            if preset.kind == .look {
                if let color = colorObject(from: stack) { out["color"] = color }
            } else if let encoded = Self.encodedEffects(stack) {
                out["effects"] = encoded
            }
        case .textStyle(let style):
            out["textStyle"] = Self.encodedTextStyle(style.style)
            if let fillMode = style.fillMode { out["textFillMode"] = fillMode.rawValue }
            if let animation = style.animation { out["textAnimation"] = animation.preset.rawValue }
        }
        return out
    }

    private static func encodedEffects(_ stack: [Effect]) -> [[String: Any]]? {
        guard let data = try? JSONEncoder().encode(stack),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        let cleaned = compactEffects(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func encodedTextStyle(_ style: TextStyle) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(style),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(TextStyle()),
              let defaults = try? JSONSerialization.jsonObject(with: defaultData) as? [String: Any] else { return [:] }
        return strippingDefaults(raw, defaults)
    }

    @MainActor
    private static func requirePreset(_ id: String, in store: PresetStore) throws -> StylePreset {
        guard let preset = store.preset(id: id) else {
            throw ToolError("Preset not found: \(id). Call manage_presets with action='list'.")
        }
        return preset
    }

    private static func requireEditable(_ preset: StylePreset) throws {
        guard !preset.isBuiltIn else {
            throw ToolError("'\(preset.name)' is a built-in preset and cannot be renamed or deleted.")
        }
    }

    private static func presetKind(_ raw: String) throws -> PresetKind {
        guard let kind = PresetKind(rawValue: raw) else {
            throw ToolError("manage_presets: unknown kind '\(raw)'. Use \(PresetKind.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return kind
    }

    private static func expectedClipDescription(_ kind: PresetKind) -> String {
        switch kind {
        case .look, .effects: "a video, image, text, or adjustment clip"
        case .textStyle: "a text clip"
        }
    }

    private static func captureHint(_ kind: PresetKind) -> String {
        switch kind {
        case .look: "Grade it with apply_color first."
        case .effects: "Add non-color effects with apply_effect first."
        case .textStyle: "Style it with update_text first."
        }
    }

    private static func defaultName(kind: PresetKind, clip: Clip) -> String {
        if kind == .textStyle, let text = clip.textContent?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return String(text.prefix(24))
        }
        return kind.displayName
    }

    private static func okJSON(_ out: [String: Any]) throws -> ToolResult {
        guard let json = jsonString(out) else { throw ToolError("Failed to encode result.") }
        return .ok(json)
    }
}
