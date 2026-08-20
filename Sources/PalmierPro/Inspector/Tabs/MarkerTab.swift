import SwiftUI

/// Inspector for the marker selected in the timeline ruler.
struct MarkerTab: View {
    @Environment(EditorViewModel.self) var editor
    let marker: TimelineMarker

    @State private var name: String
    @State private var note: String
    @FocusState private var nameFocused: Bool

    init(marker: TimelineMarker) {
        self.marker = marker
        _name = State(initialValue: marker.name)
        _note = State(initialValue: marker.note)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                EditorPanelGroup("Marker", contentSpacing: AppTheme.Spacing.smMd) {
                    InspectorRow(label: "Name") {
                        TextField(marker.kind.label, text: $name)
                            .textFieldStyle(.plain)
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .focused($nameFocused)
                            .editorValueField(active: nameFocused)
                            .onSubmit { commitName() }
                    }
                    InspectorRow(label: "Kind") {
                        Menu {
                            ForEach(MarkerKind.allCases, id: \.self) { kind in
                                Button(kind.label) {
                                    editor.updateMarker(id: marker.id, .init(kind: kind))
                                }
                            }
                        } label: {
                            EditorMenuValue(text: marker.kind.label)
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    }
                    InspectorRow(label: "Color") {
                        Menu {
                            ForEach(MarkerColor.allCases, id: \.self) { color in
                                Button(color.label) {
                                    editor.updateMarker(id: marker.id, .init(color: color))
                                }
                            }
                        } label: {
                            HStack(spacing: AppTheme.Spacing.sm) {
                                Circle()
                                    .fill(AppTheme.Marker.color(marker.color))
                                    .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
                                EditorMenuValue(text: marker.color.label)
                            }
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    }
                    if marker.kind == .todo {
                        InspectorRow(label: "Done") {
                            Toggle("", isOn: Binding(
                                get: { marker.done },
                                set: { editor.updateMarker(id: marker.id, .init(done: $0)) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                    }
                    InspectorRow(label: "Position") {
                        Button {
                            editor.seekToFrame(marker.frame)
                        } label: {
                            Text(formatTimecode(frame: marker.frame, fps: editor.timeline.fps))
                                .font(.system(size: AppTheme.FontSize.sm).monospacedDigit())
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        .buttonStyle(.plain)
                        .help("Move the playhead to this marker")
                    }
                }

                EditorPanelGroup("Note", contentSpacing: AppTheme.Spacing.smMd) {
                    TextContentField(text: $note) { committed in
                        editor.updateMarker(id: marker.id, .init(note: committed))
                    }
                    .frame(minHeight: AppTheme.EditorPanel.textEditorMinHeight)
                }

                HStack {
                    Spacer()
                    Button("Delete Marker") {
                        editor.removeMarker(id: marker.id)
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
        .onChange(of: nameFocused) { _, focused in
            if !focused { commitName() }
        }
        .onChange(of: editor.markerEditRequestTick) { _, _ in
            nameFocused = true
        }
    }

    private func commitName() {
        editor.updateMarker(id: marker.id, .init(name: name))
    }
}
