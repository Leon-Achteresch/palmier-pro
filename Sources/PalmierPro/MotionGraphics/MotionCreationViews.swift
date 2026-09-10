import SwiftUI

struct MotionNewSceneView: View {
    let session: MotionEditorSession
    @State private var name = L10n.string("Motion Scene")
    @State private var runtime: MotionSceneRuntime = .web

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Label(L10n.string("New Motion Scene"), systemImage: "square.stack.3d.up")
                .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))
            Text(L10n.string("Create components, import your project’s UI, and animate layers on the canvas."))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            TextField(L10n.string("Name"), text: $name).textFieldStyle(.roundedBorder)
            Picker(L10n.string("Component Type"), selection: $runtime) {
                Text(verbatim: "React").tag(MotionSceneRuntime.web)
                if MotionSceneRuntime.reactNative.isAvailable {
                    Text(verbatim: "React Native").tag(MotionSceneRuntime.reactNative)
                }
            }
            Text(L10n.string("The scene uses the current timeline’s dimensions and frame rate."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Button(L10n.string("Create Scene")) { session.createScene(name: name, runtime: runtime) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .disabled(session.busy)
        .frame(width: AppTheme.MotionEditor.creationWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MotionNewComponentView: View {
    @Bindable var session: MotionEditorSession
    let runtime: MotionSceneRuntime
    @State private var name = L10n.string("Component")
    @State private var template: MotionComponentTemplate = .card
    @State private var source: String
    @State private var showsSource = false

    init(session: MotionEditorSession, runtime: MotionSceneRuntime) {
        self.session = session
        self.runtime = runtime
        _source = State(initialValue: MotionComponentTemplate.card.source(runtime: runtime))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(L10n.string("New Component"))
                .font(.system(size: AppTheme.FontSize.title1, weight: AppTheme.FontWeight.semibold))
            Text(L10n.string("Start with a template, then edit its text, colors, and animation in the inspector."))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            TextField(L10n.string("Name"), text: $name).textFieldStyle(.roundedBorder)
                .disabled(session.busy)
            Picker(L10n.string("Template"), selection: $template) {
                ForEach(MotionComponentTemplate.allCases, id: \.self) { template in
                    Text(template.title).tag(template)
                }
            }
            .disabled(session.busy)
            .onChange(of: template) { _, value in source = value.source(runtime: runtime) }
            DisclosureGroup(L10n.string("Edit Component Source"), isExpanded: $showsSource) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text(L10n.string("Provide a default React export. Use Import Component for files with local dependencies."))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    TextEditor(text: $source)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .frame(height: AppTheme.MotionEditor.sourceHeight)
                        .border(AppTheme.Border.subtleColor, width: AppTheme.BorderWidth.thin)
                        .disabled(session.busy)
                }
            }
            if let error = session.error {
                Label { Text(verbatim: error).textSelection(.enabled) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.system(size: AppTheme.FontSize.sm))
            }
            HStack(spacing: AppTheme.Spacing.sm) {
                if session.busy {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("Creating component…"))
                }
                Spacer()
                Button(L10n.string("Cancel")) {
                    if session.busy { session.cancelOperation() }
                    else { session.showingComponentCreation = false }
                }.keyboardShortcut(.cancelAction)
                Button(L10n.string("Create Component")) { session.createComponent(name: name, source: source) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(session.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: AppTheme.MotionEditor.creationWidth)
        .interactiveDismissDisabled(session.busy)
    }
}
