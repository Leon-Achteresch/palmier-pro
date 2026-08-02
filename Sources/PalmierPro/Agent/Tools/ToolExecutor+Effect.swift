import Foundation

extension ToolExecutor {
    fileprivate struct ApplyEffectInput: DecodableToolArgs {
        struct Entry: Decodable {
            let type: String
            let enabled: Bool?
        }
        let clipIds: [String]
        let effects: [Entry]?
        let remove: [String]?
        static let allowedKeys: Set<String> = ["clipIds", "effects", "remove"]
    }

    /// One parsed param write: a static value or an animated track for the clip's own frame range.
    fileprivate enum EffectParamWrite {
        case value(Double)
        case track(KeyframeTrack<Double>)
        case clearTrack
    }

    /// Generic, registry-driven effect stack editing for non-color effects (apply_color owns color.*).
    func applyEffect(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: ApplyEffectInput = try decodeToolArgs(args, path: "apply_effect")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }
        let adds = input.effects ?? []
        let removes = input.remove ?? []
        guard !adds.isEmpty || !removes.isEmpty else {
            throw ToolError("Provide effects to add/update or remove types to delete.")
        }

        let rawEntries = args["effects"] as? [Any] ?? []
        var writes: [[String: EffectParamWrite]] = []
        var animated = false
        for (i, e) in adds.enumerated() {
            guard let d = EffectRegistry.descriptor(id: e.type) else {
                let available = EffectRegistry.all.map(\.id).filter { !$0.hasPrefix("color.") }
                throw ToolError("Unknown effect '\(e.type)'. Available: \(available.joined(separator: ", ")). color.* grades go through apply_color.")
            }
            guard !e.type.hasPrefix("color.") else {
                throw ToolError("'\(e.type)' is a color grade — use apply_color, not apply_effect.")
            }
            guard !e.type.hasPrefix("mockup.") || editor.enabledAddons.contains(ProjectAddon.deviceMockups) else {
                throw ToolError("'\(e.type)' requires the Device Mockups addon, which is disabled for this project. Ask the user to enable it in the project inspector under Addons.")
            }
            let path = "apply_effect.effects[\(i)]"
            guard let rawParams = (rawEntries.count > i ? rawEntries[i] as? [String: Any] : nil)?["params"] else {
                writes.append([:])
                continue
            }
            guard let params = rawParams as? [String: Any] else {
                throw ToolError("\(path).params: expected an object of param name → number or keyframe rows")
            }
            let allowed = Set(d.params.map(\.key))
            let unknown = Set(params.keys).subtracting(allowed)
            guard unknown.isEmpty else {
                throw ToolError("\(e.type): unknown param(s) '\(unknown.sorted().joined(separator: "', '"))'. Allowed: \(allowed.sorted().joined(separator: ", ")).")
            }
            var entryWrites: [String: EffectParamWrite] = [:]
            for spec in d.params {
                guard let raw = params[spec.key] else { continue }
                if let rows = raw as? [Any] {
                    guard !rows.isEmpty else { entryWrites[spec.key] = .clearTrack; continue }
                    let track = try Self.parseScalarKeyframes(rows, path: "\(path).params.\(spec.key)", valueName: spec.key)
                    entryWrites[spec.key] = .track(Self.clamped(track, to: spec.range))
                    animated = true
                } else if !isJSONBoolean(raw), let value = (raw as? NSNumber)?.doubleValue {
                    let clamped = min(spec.range.upperBound, max(spec.range.lowerBound, value))
                    entryWrites[spec.key] = .value((clamped * 1000).rounded() / 1000)
                } else {
                    throw ToolError("\(path).params.\(spec.key): expected a number or keyframe rows [[frame, \(spec.key), interp?], ...]")
                }
            }
            writes.append(entryWrites)
        }

        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType == .video || clip.mediaType == .image || clip.mediaType == .text else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; apply_effect needs a video, image, or text clip.")
            }
        }

        let snapshot = timelineSnapshot(editor)
        let actionName = input.clipIds.count == 1 ? "Apply Effect (Agent)" : "Apply Effect ×\(input.clipIds.count) (Agent)"
        editor.undo.perform(actionName) {
            editor.mutateClips(ids: Set(input.clipIds), actionName: actionName) { clip in
                var stack = clip.effects ?? []
                for type in removes { stack.removeAll { $0.type == type } }
                for (i, e) in adds.enumerated() {
                    guard let d = EffectRegistry.descriptor(id: e.type) else { continue }
                    var effect = stack.first { $0.type == e.type } ?? d.makeEffect()
                    if let enabled = e.enabled { effect.enabled = enabled }
                    for (key, write) in writes[i] {
                        let existing = effect.params[key]
                        switch write {
                        case .value(let v):
                            effect.params[key] = EffectParam(value: v)
                        case .track(let t):
                            effect.params[key] = EffectParam(value: existing?.value, track: t)
                        case .clearTrack:
                            effect.params[key] = EffectParam(value: existing?.value ?? existing?.track?.keyframes.first?.value)
                        }
                    }
                    stack.removeAll { $0.type == e.type }
                    stack.insert(effect, at: EffectRegistry.insertIndex(stack, for: e.type))
                }
                clip.effects = stack.isEmpty ? nil : stack
            }
        }
        let notes = animated
            ? ["Animated params use clip-relative frames, like set_keyframes."]
            : []
        return mutationResult(editor, since: snapshot, touched: input.clipIds, notes: notes)
    }

    fileprivate static func clamped(_ track: KeyframeTrack<Double>, to range: ClosedRange<Double>) -> KeyframeTrack<Double> {
        KeyframeTrack(keyframes: track.keyframes.map {
            let v = min(range.upperBound, max(range.lowerBound, $0.value))
            return $0.withValue((v * 1000).rounded() / 1000)
        })
    }
}
