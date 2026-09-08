import SwiftUI

extension InspectorView {

    @ViewBuilder
    func motionSection(clips: [Clip]) -> some View {
        let targets = clips.filter { clip in
            clip.supportsKeyframes(for: .scale) && clip.supportsKeyframes(for: .opacity)
        }
        if !targets.isEmpty {
            EditorPanelGroup(L10n.string("Motion"), contentSpacing: AppTheme.Spacing.smMd) {
                MotionPresetPicker(editor: editor, clipIds: targets.map(\.id))
            }
        }
    }
}

struct MotionPresetPicker: View {
    let editor: EditorViewModel
    let clipIds: [String]

    @State private var intensity: Double = 50

    private var categories: [(MotionPresetCategory, String)] {
        [
            (.entrance, L10n.string("Entrance")),
            (.emphasis, L10n.string("Emphasis")),
            (.exit, L10n.string("Exit")),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Intensity"))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Slider(value: $intensity, in: 0...100)
                    .controlSize(.mini)
                Text(verbatim: "\(Int(intensity))")
                    .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.lg, alignment: .trailing)
            }
            ForEach(categories, id: \.0) { category, title in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(title)
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    FlowingPresetGrid(
                        presets: MotionPreset.allCases.filter { $0.category == category }
                    ) { preset in
                        apply(preset)
                    }
                }
            }
        }
    }

    private func apply(_ preset: MotionPreset) {
        let rampFrames = max(Int((preset.defaultDurationSeconds * Double(editor.timeline.fps)).rounded()), 1)
        editor.applyMotionPreset(
            preset,
            intensity: intensity / 100,
            rampFrames: rampFrames,
            to: clipIds
        )
    }
}

private struct FlowingPresetGrid: View {
    let presets: [MotionPreset]
    let onSelect: (MotionPreset) -> Void

    private let columns = [GridItem(.adaptive(minimum: 88), spacing: AppTheme.Spacing.xs)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ForEach(presets, id: \.self) { preset in
                Button {
                    onSelect(preset)
                } label: {
                    Text(verbatim: preset.displayName)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppTheme.Spacing.xs)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }
}
