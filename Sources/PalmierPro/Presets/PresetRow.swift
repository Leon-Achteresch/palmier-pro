import AppKit
import SwiftUI

struct PresetRow: View {
    let kind: PresetKind
    let clips: [Clip]
    @Environment(EditorViewModel.self) private var editor
    private var store: PresetStore { .shared }

    @State private var pendingName = ""
    @State private var isNaming = false
    @State private var pendingDeletion: StylePreset?

    private var saved: [StylePreset] {
        store.library(kind: kind).filter { !$0.isBuiltIn }
    }

    private var capturableClip: Clip? {
        clips.compactMap { editor.clipFor(id: $0.id) }
            .first { kind.payload(from: $0) != nil }
    }

    private var hasTargets: Bool {
        !PresetApplication.eligibleTargets(clips.map(\.id), kind: kind, editor: editor).applied.isEmpty
    }

    var body: some View {
        InspectorRow(label: "Presets") {
            HStack(spacing: AppTheme.Spacing.sm) {
                applyMenu
                saveButton
            }
        }
        .alert("Save \(kind.displayName) Preset", isPresented: $isNaming) {
            TextField("Name", text: $pendingName)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The preset is available in every project.")
        }
        .alert(
            "Delete “\(pendingDeletion?.name ?? "")”?",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } })
        ) {
            Button("Delete", role: .destructive) { confirmDeletion() }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("The preset is removed from every project. This cannot be undone.")
        }
    }

    private var applyMenu: some View {
        let presets = saved
        let enabled = hasTargets
        return Menu {
            if presets.isEmpty {
                Text("No saved \(kind.displayName.lowercased()) presets")
            } else {
                ForEach(presets) { preset in
                    Button(preset.name) { PresetApplication.apply(preset, to: clips.map(\.id), editor: editor) }
                        .disabled(!enabled)
                }
                Divider()
                Menu("Delete") {
                    ForEach(presets) { preset in
                        Button(preset.name) { pendingDeletion = preset }
                    }
                }
            }
        } label: {
            EditorMenuValue(text: presets.isEmpty ? "None saved" : "Apply…")
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
        .help("Apply a saved \(kind.displayName.lowercased()) preset")
    }

    private var saveButton: some View {
        Button {
            pendingName = kind.displayName
            isNaming = true
        } label: {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .disabled(capturableClip == nil)
        .help(
            capturableClip == nil
                ? "Nothing to save from this selection"
                : "Save the current \(kind.displayName.lowercased()) as a preset"
        )
        .accessibilityLabel("Save \(kind.displayName) Preset")
    }

    private func save() {
        guard let clip = capturableClip, let payload = kind.payload(from: clip) else { return }
        let name = pendingName
        Task {
            do {
                try await store.save(name: name, kind: kind, payload: payload)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    private func confirmDeletion() {
        guard let preset = pendingDeletion else { return }
        pendingDeletion = nil
        Task {
            do {
                try await store.delete(id: preset.id)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}
