import Foundation

@MainActor
enum PresetApplication {
    struct Outcome {
        let applied: [String]
        let skipped: [String]
    }

    static func actionName(for preset: StylePreset) -> String {
        "Apply \(preset.name) \(preset.kind.displayName)"
    }

    static func eligibleTargets(_ clipIds: [String], kind: PresetKind, editor: EditorViewModel) -> Outcome {
        var applied: [String] = []
        var skipped: [String] = []
        var seen = Set<String>()
        for id in clipIds where seen.insert(id).inserted {
            guard let clip = editor.clipFor(id: id) else {
                skipped.append(id)
                continue
            }
            if kind.supports(clip) { applied.append(id) } else { skipped.append(id) }
        }
        return Outcome(applied: applied, skipped: skipped)
    }

    @discardableResult
    static func apply(
        _ preset: StylePreset,
        to clipIds: [String],
        editor: EditorViewModel,
        actionName: String? = nil
    ) -> [String] {
        let targets = eligibleTargets(clipIds, kind: preset.kind, editor: editor).applied
        guard !targets.isEmpty else { return [] }
        let donor = preset.donorClip
        let attribute = preset.kind.attribute
        editor.commitClipProperties(clipIds: targets, actionName: actionName ?? Self.actionName(for: preset)) { clip in
            clip.absorb([attribute], from: donor)
        }
        return targets
    }
}
