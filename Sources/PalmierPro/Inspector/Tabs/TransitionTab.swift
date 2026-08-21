import SwiftUI

/// Inspector for the transition selected at a cut. Every control re-resolves the transition
/// against its track before committing, so a refused edit leaves the timeline untouched.
struct TransitionTab: View {
    @Environment(EditorViewModel.self) var editor
    let resolved: ResolvedTransition

    private var transition: ClipTransition { resolved.transition }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                EditorPanelGroup("Transition", contentSpacing: AppTheme.Spacing.smMd) {
                    InspectorRow(label: "Style") {
                        Menu {
                            ForEach(TransitionStyle.allCases, id: \.self) { style in
                                Button(style.displayName) { apply(.init(style: style)) }
                            }
                        } label: {
                            EditorMenuValue(text: transition.style.displayName)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    }

                    if transition.style.requiresDirection {
                        InspectorRow(label: "Direction") {
                            Menu {
                                ForEach(TransitionDirection.allCases, id: \.self) { direction in
                                    Button(direction.displayName) { apply(.init(direction: direction)) }
                                }
                            } label: {
                                EditorMenuValue(text: (transition.direction ?? .left).displayName)
                            }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                        }
                    }

                    InspectorRow(label: "Duration") {
                        ScrubbableNumberField(
                            value: Double(transition.durationFrames),
                            range: Double(ClipTransition.minimumDurationFrames)...Double(ClipTransition.maximumDurationFrames),
                            valueSuffix: " f",
                            onChanged: nil
                        ) { frames in
                            apply(.init(durationFrames: Int(frames.rounded())))
                        }
                    }

                    InspectorRow(label: "Alignment") {
                        Menu {
                            ForEach(TransitionAlignment.allCases, id: \.self) { alignment in
                                Button(alignment.displayName) { apply(.init(alignment: alignment)) }
                            }
                        } label: {
                            EditorMenuValue(text: transition.alignment.displayName)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    }

                    InspectorRow(label: "Position") {
                        Button {
                            editor.seekToFrame(resolved.window.cutFrame)
                        } label: {
                            Text(formatTimecode(frame: resolved.window.cutFrame, fps: editor.timeline.fps))
                                .font(.system(size: AppTheme.FontSize.sm).monospacedDigit())
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        .buttonStyle(.plain)
                        .help("Move the playhead to this cut")
                    }
                }

                HStack {
                    Spacer()
                    Button("Delete Transition") {
                        editor.removeTransition(id: transition.id)
                        editor.selectedTransitionIds.remove(transition.id)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.sm)
                }
                .padding(.horizontal, AppTheme.Spacing.smMd)
                .padding(.top, AppTheme.Spacing.md)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func apply(_ edit: EditorViewModel.TransitionEdit) {
        do {
            try editor.updateTransition(id: transition.id, edit)
        } catch {
            editor.refuseWithToast(error.message)
        }
    }
}

extension TransitionDirection {
    var displayName: String {
        switch self {
        case .left: "Left"
        case .right: "Right"
        case .up: "Up"
        case .down: "Down"
        }
    }
}

extension TransitionAlignment {
    var displayName: String {
        switch self {
        case .centered: "Centered on Cut"
        case .startAtCut: "Start at Cut"
        case .endAtCut: "End at Cut"
        }
    }
}
