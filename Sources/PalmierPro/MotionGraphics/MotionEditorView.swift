import AppKit
import SwiftUI

struct MotionEditorPresentation: ViewModifier {
    @Environment(EditorViewModel.self) private var editor

    private struct Selection: Identifiable { var id: String }

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { editor.motionScenes.presentedMediaRef.map { Selection(id: $0) } },
            set: { editor.motionScenes.presentedMediaRef = $0?.id }
        )) { selection in
            MotionEditorView(editor: editor, mediaRef: selection.id)
        }
    }
}

struct MotionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var session: MotionEditorSession

    init(editor: EditorViewModel, mediaRef: String) {
        _session = State(initialValue: MotionEditorSession(editor: editor, mediaRef: mediaRef))
    }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            MotionEditorToolbar(session: session, close: { dismiss() })
            Divider()
            if session.scene != nil {
                HStack(spacing: AppTheme.Spacing.zero) {
                    MotionLayerLibrary(session: session)
                        .frame(width: AppTheme.MotionEditor.libraryWidth)
                    Divider()
                    MotionEditorStage(session: session)
                    Divider()
                    MotionEditorInspector(session: session)
                        .frame(width: AppTheme.MotionEditor.inspectorWidth)
                }
                Divider()
                MotionEditorTimeline(session: session)
                    .frame(height: AppTheme.MotionEditor.timelineHeight)
            } else if session.mediaRef == "new" {
                MotionNewSceneView(session: session)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            MotionEditorStatus(session: session)
        }
        .frame(width: AppTheme.MotionEditor.width, height: AppTheme.MotionEditor.height)
        .background(AppTheme.Background.baseColor)
        .task { await session.open() }
        .onChange(of: session.editor.motionScenes.changeSequence) { _, _ in session.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            session.cancelGesture()
            session.stopPlayback()
        }
        .onDisappear { session.close() }
        .onExitCommand {
            if session.busy { session.cancelOperation() }
            else if session.scene == nil { dismiss() }
            else { session.cancelGesture(); session.stopPlayback() }
        }
        .interactiveDismissDisabled(session.busy)
        .sheet(isPresented: $session.showingComponentCreation) {
            if let scene = session.scene { MotionNewComponentView(session: session, runtime: scene.runtime) }
        }
        .sheet(item: $session.componentCandidate) { candidate in
            MotionComponentUpdateView(session: session, candidate: candidate)
        }
    }
}

private struct MotionEditorToolbar: View {
    @Bindable var session: MotionEditorSession
    let close: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Text(L10n.string("Motion Editor"))
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
            if session.scene != nil {
                Menu {
                    ForEach([MotionNode.Kind.text, .shape, .path, .group, .camera], id: \.self) { kind in
                        Button { session.add(kind) } label: { Label(kind.title, systemImage: kind.symbol) }
                    }
                    Button(L10n.string("Image…")) { session.importImage() }
                } label: { Label(L10n.string("Add Layer"), systemImage: "plus") }
                .disabled(session.busy || session.scene == nil)
                Menu(L10n.string("Animate")) {
                    Stepper(L10n.string("Stagger: \(session.staggerFrames) frames"), value: $session.staggerFrames, in: 0...120)
                    ForEach(MotionRecipe.Kind.allCases, id: \.self) { kind in
                        Button(kind.title) { session.addRecipe(kind) }
                    }
                }.disabled(session.selection.isEmpty || session.busy)
                Menu(L10n.string("Align")) {
                    ForEach(MotionAlignment.allCases, id: \.self) { alignment in
                        Button(alignment.title) { session.align(alignment) }
                    }
                }.disabled(session.selection.isEmpty || session.busy)
                Toggle(L10n.string("Auto Keyframe"), isOn: $session.autoKey).toggleStyle(.button)
                Toggle(L10n.string("Snap"), isOn: $session.snapping).toggleStyle(.button)
                Toggle(L10n.string("Interact"), isOn: $session.interacting).toggleStyle(.button)
                    .onChange(of: session.interacting) { _, _ in session.resetInteraction() }
            }
            Spacer()
            if session.scene != nil {
                Button(L10n.string("Add to Timeline")) { session.placeOnTimeline() }
                    .disabled(session.busy)
            }
            Button(session.scene == nil ? L10n.string("Cancel") : L10n.string("Done"), action: close).disabled(session.busy)
        }
        .controlSize(.small)
        .padding(AppTheme.Spacing.smMd)
    }
}

private struct MotionEditorStatus: View {
    let session: MotionEditorSession

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if session.busy {
                ProgressView().controlSize(.small)
                Text(L10n.string("Saving motion scene…"))
                Button(L10n.string("Cancel")) { session.cancelOperation() }
            } else if let error = session.error {
                Image(systemName: "exclamationmark.triangle")
                Text(verbatim: error).lineLimit(2).textSelection(.enabled)
            } else {
                Text(L10n.string("Select a layer to edit its properties and animation."))
            }
            Spacer()
            if let scene = session.scene { Text(verbatim: "\(scene.width) × \(scene.height) · \(scene.fps.formatted()) fps") }
        }
        .font(.system(size: AppTheme.FontSize.xs))
        .foregroundStyle(AppTheme.Text.secondaryColor)
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.sm)
    }
}

private struct MotionLayerLibrary: View {
    @Bindable var session: MotionEditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(L10n.string("Components")).font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
            Button {
                session.error = nil
                session.showingComponentCreation = true
            } label: { Label(L10n.string("New Component…"), systemImage: "plus") }
                .disabled(session.busy)
            TextField(L10n.string("Search components"), text: $session.search)
                .textFieldStyle(.roundedBorder)
            TextField(L10n.string("Export name"), text: $session.importExportName).textFieldStyle(.roundedBorder)
            Button { session.importComponent() } label: {
                Label(L10n.string("Import Component…"), systemImage: "square.and.arrow.down")
            }.disabled(session.busy)
            if session.scene?.components.isEmpty == true && session.repositoryIndex == nil {
                Text(L10n.string("Create a component or import one from your React project."))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            Button(L10n.string("Browse Repository…")) { session.browseRepository() }.disabled(session.busy)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    ForEach(session.scene?.components.filter { session.search.isEmpty || $0.name.localizedCaseInsensitiveContains(session.search) } ?? []) { component in
                        Button { session.add(.component, componentID: component.id) } label: {
                            Label { Text(verbatim: component.name) } icon: { Image(systemName: "square.stack.3d.up") }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(L10n.string("Edit Component Controls")) { session.selection = []; session.selectedComponentID = component.id }
                        }
                        .padding(.vertical, AppTheme.Spacing.xs)
                        .disabled(session.busy)
                    }
                    ForEach(session.repositoryIndex?.components.filter { session.search.isEmpty || $0.id.localizedCaseInsensitiveContains(session.search) } ?? []) { item in
                        Button { session.importRepositoryComponent(item) } label: {
                            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                                Text(verbatim: item.exportName)
                                Text(verbatim: item.path).foregroundStyle(AppTheme.Text.secondaryColor).lineLimit(1)
                            }
                        }.buttonStyle(.plain).disabled(session.busy)
                    }
                    if session.repositoryIndex?.truncated == true {
                        Text(L10n.string("Index limited to 2,000 source files. Choose a smaller folder to see more."))
                    }
                }
            }
            .frame(maxHeight: AppTheme.MotionEditor.curveHeight)
            Divider()
            HStack {
                Text(L10n.string("Layers")).font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                Spacer()
                Button { session.perform([.group(ids: session.orderedSelection, name: L10n.string("Group"))], name: "Group Motion Layers") } label: {
                    Image(systemName: "folder.badge.plus")
                }.disabled(session.selection.isEmpty || session.busy)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    ForEach(session.scene?.nodes ?? []) { node in
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: node.kind.symbol)
                                .frame(width: AppTheme.IconSize.sm)
                            Text(verbatim: node.name).lineLimit(1)
                            Spacer(minLength: AppTheme.Spacing.zero)
                            Button { session.perform([.lock(ids: [node.id], locked: !node.locked)]) } label: {
                                Image(systemName: node.locked ? "lock.fill" : "lock.open")
                            }
                            Button { session.perform([.visibility(ids: [node.id], hidden: !node.hidden)]) } label: {
                                Image(systemName: node.hidden ? "eye.slash" : "eye")
                            }.disabled(node.locked)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .padding(AppTheme.Spacing.xs)
                        .padding(.leading, node.parentID == nil ? AppTheme.Spacing.zero : AppTheme.Spacing.md)
                        .background(session.selection.contains(node.id) ? AppTheme.Background.raisedColor : AppTheme.Background.baseColor)
                        .contentShape(Rectangle())
                        .onTapGesture { session.select(node.id, extending: NSEvent.modifierFlags.contains(.command)) }
                        .contextMenu {
                            Button(L10n.string("Duplicate")) { session.perform([.duplicate(ids: [node.id])], name: "Duplicate Motion Layers") }
                            if node.kind == .group {
                                Button(L10n.string("Ungroup")) { session.perform([.ungroup(id: node.id)], name: "Ungroup Motion Layers") }
                            }
                            Button(L10n.string("Delete")) { session.perform([.remove(ids: [node.id])], name: "Delete Motion Layers") }
                        }
                    }
                }
            }
            .onDeleteCommand { if !session.selection.isEmpty { session.perform([.remove(ids: session.orderedSelection)], name: "Delete Motion Layers") } }
        }
        .padding(AppTheme.Spacing.smMd)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
