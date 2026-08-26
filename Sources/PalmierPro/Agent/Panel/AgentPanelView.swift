import AppKit
import SwiftTerm
import SwiftUI

struct AgentPanelView: View {
    @Environment(EditorViewModel.self) var editor

    private static let starterPrompts: [AgentStarterPrompt] = [
        AgentStarterPrompt(
            id: "keep_best_takes",
            title: L10n.string("Keep the best takes"),
            systemImage: "scissors",
            prompt: "Tighten this edit. Keep the strongest takes, cut filler words and long silences, and leave a clean continuous cut."
        ),
        AgentStarterPrompt(
            id: "sync_multicam",
            title: L10n.string("Sync my multicam"),
            systemImage: "rectangle.on.rectangle.angled",
            prompt: "Set up my multicam. Group the matching camera angles with their audio, verify sync, and leave it ready to switch."
        ),
        AgentStarterPrompt(
            id: "generate_broll",
            title: L10n.string("Generate B-roll"),
            systemImage: "film",
            prompt: "Generate B-roll that fits this edit. Find moments that need cutaways, create matching shots, and place them where they support the story."
        ),
        AgentStarterPrompt(
            id: "score_timeline",
            title: L10n.string("Score my timeline"),
            systemImage: "music.note",
            prompt: "Generate music for this timeline. Match the mood and length, then place it on an audio track synced to the edit."
        ),
        AgentStarterPrompt(
            id: "cut_to_beat",
            title: L10n.string("Cut to the beat"),
            systemImage: "metronome",
            prompt: "Assemble my clips to the beat of a song. Detect the beats and cut or place clips so the edit hits the rhythm."
        ),
        AgentStarterPrompt(
            id: "add_captions",
            title: L10n.string("Add captions"),
            systemImage: "captions.bubble",
            prompt: "Add captions to this timeline. Transcribe the dialogue, phrase it for readability, and place text clips locked to the speech."
        ),
        AgentStarterPrompt(
            id: "make_vertical_shorts",
            title: L10n.string("Make vertical shorts"),
            systemImage: "rectangle.portrait",
            prompt: "Find the strongest moments in this video and turn each into a short-form vertical clip. Create multiple 9:16 timelines, reframe for vertical, and keep every clip tight and self-contained."
        ),
    ]

    private var service: AgentService { editor.agentService }

    private var canSend: Bool {
        !service.isStreaming &&
        service.canStream &&
        !service.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @State private var terminals = AgentTerminalStore()
    @State private var activeTerminal: AgentTerminalCLI?

    private var terminalView: LocalProcessTerminalView? {
        activeTerminal.flatMap { terminals.existingView(for: $0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            floatingTabBar
            if let terminalView {
                AgentTerminalView(terminal: terminalView)
            } else {
                messageList
                footer
            }
        }
    }

    private var terminalDirectory: URL? {
        editor.projectURL?.deletingLastPathComponent()
    }

    private var runningTerminals: [AgentTerminalCLI] {
        AgentTerminalCLI.allCases.filter { terminals.existingView(for: $0) != nil }
    }

    private var floatingTabBar: some View {
        GlassEffectContainer {
            HStack(spacing: AppTheme.Spacing.xs) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            ForEach(service.openSessions) { session in
                                PanelTab(
                                    title: session.title,
                                    systemImage: "bubble.left",
                                    isActive: terminalView == nil && session.id == service.currentSessionId,
                                    onSelect: {
                                        activeTerminal = nil
                                        service.selectSession(session.id)
                                    },
                                    onClose: { service.closeTab(session.id) }
                                )
                                .id(session.id)
                            }
                            ForEach(runningTerminals) { cli in
                                PanelTab(
                                    title: cli.title,
                                    systemImage: cli.systemImage,
                                    isActive: activeTerminal == cli,
                                    onSelect: { activeTerminal = cli },
                                    onClose: {
                                        terminals.terminate(cli)
                                        if activeTerminal == cli { activeTerminal = nil }
                                    }
                                )
                                .id(cli.id)
                            }
                        }
                    }
                    .onChange(of: service.currentSessionId) { _, new in
                        guard let new else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(new, anchor: .center) }
                    }
                }
                newTabButton
                historyButton
                ViewSkillsButton()
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(maxWidth: .infinity)
            .frame(height: Layout.panelHeaderHeight)
            .glassEffect(.regular, in: .rect(cornerRadius: AppTheme.Radius.lg))
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
    }

    private var newTabButton: some View {
        Menu {
            Button {
                activeTerminal = nil
                service.newChat()
            } label: {
                Label("New Chat", systemImage: "bubble.left")
            }
            Divider()
            ForEach(AgentTerminalCLI.allCases) { cli in
                Button {
                    terminals.view(for: cli, workingDirectory: terminalDirectory)
                    activeTerminal = cli
                } label: {
                    Label(cli.title, systemImage: cli.systemImage)
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .help(L10n.string("New chat or terminal"))
    }

    @State private var showHistory = false
    @State private var isScrolledFromBottom = false

    private var historyButton: some View {
        Button { showHistory.toggle() } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.string("Chat history"))
        .popover(isPresented: $showHistory, arrowEdge: .top) {
            ChatHistoryList(
                sessions: service.sessions.sorted { $0.updatedAt > $1.updatedAt },
                currentId: service.currentSessionId,
                onSelect: { id in
                    service.selectSession(id)
                    showHistory = false
                },
                onDelete: { service.deleteSession($0) }
            )
        }
    }

    private struct ModelGroup: Identifiable {
        let id: String
        let models: [AgentModel]
    }

    private var modelGroups: [ModelGroup] {
        let grouped = Dictionary(grouping: service.availableModels.filter { !$0.isCLIAgent }) { model in
            model.provider == .google
                ? "Google AI"
                : model.providerModelId.split(separator: "/").first.map(String.init) ?? "OpenRouter"
        }
        return grouped
            .map { ModelGroup(id: $0.key, models: $0.value) }
            .sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    private var modelPicker: some View {
        Menu {
            ForEach(AgentModel.cliModels) { model in
                Button { service.model = model } label: { Text(verbatim: model.displayName) }
            }
            Divider()
            ForEach(modelGroups) { group in
                Menu(group.id) {
                    ForEach(group.models) { model in
                        Button { service.model = model } label: { Text(verbatim: model.displayName) }
                    }
                }
            }
        } label: {
            footerPickerLabel(service.model.displayName) {
                if service.model.isCLIAgent {
                    Image(systemName: "terminal")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .layoutPriority(1)
        .accessibilityLabel(L10n.string("Model"))
        .accessibilityValue(Text(verbatim: service.model.displayName))
        .help(L10n.string("Model"))
    }

    private var reasoningEffortPicker: some View {
        Menu {
            ForEach(service.model.supportedReasoningEfforts, id: \.self) { effort in
                Button {
                    service.reasoningEffort = effort
                } label: {
                    menuOptionLabel(
                        L10n.string(key: effort.labelKey),
                        selected: effort == service.reasoningEffort
                    )
                }
            }
        } label: {
            footerPickerLabel(L10n.string(key: service.reasoningEffort.labelKey)) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
                    .accessibilityHidden(true)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(L10n.string("Reasoning effort"))
        .accessibilityValue(L10n.string(key: service.reasoningEffort.labelKey))
        .help(L10n.string("Reasoning effort"))
    }

    private func footerPickerLabel<Artwork: View>(
        _ title: String,
        @ViewBuilder artwork: () -> Artwork
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Text(verbatim: title)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.tail)
            artwork()
                .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                .clipped()
        }
    }

    @ViewBuilder
    private func menuOptionLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label {
                Text(verbatim: title)
            } icon: {
                Image(systemName: "checkmark")
            }
        } else {
            Text(verbatim: title)
        }
    }

    @ViewBuilder
    private var byokIndicator: some View {
        if let provider = service.activeProvider {
            Image(systemName: "key")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: provider.chatPresentation.byokLabel))
                .help(provider.chatPresentation.byokHelp)
        }
    }

    private var toolResults: [String: ToolRunResult] {
        var out: [String: ToolRunResult] = [:]
        for msg in service.messages where msg.role == .user {
            for block in msg.blocks {
                if case let .toolResult(id, content, isError) = block {
                    out[id] = ToolRunResult(content: content, isError: isError)
                }
            }
        }
        return out
    }

    private var messageList: some View {
        Group {
            if service.messages.isEmpty && !service.isStreaming {
                VStack(spacing: AppTheme.Spacing.smMd) {
                    emptyState
                    errorBanner
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(.horizontal, AppTheme.Spacing.lgXl)
            } else {
                scrollingMessages
            }
        }
    }

    private var scrollingMessages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                    let results = toolResults
                    ForEach(service.messages) { msg in
                        AgentMessageView(message: msg, toolResults: results)
                            .id(msg.id)
                    }
                    if service.isStreaming {
                        ThinkingDots().id("streaming-indicator")
                    }
                    errorBanner
                        .padding(.top, AppTheme.Spacing.sm)
                }
                .padding(.horizontal, AppTheme.Spacing.lgXl)
                .padding(.top, AppTheme.Spacing.mdLg)
                .padding(.bottom, AppTheme.Spacing.smMd)
                .frame(maxWidth: Layout.chatColumnMax)
                .frame(maxWidth: .infinity)
                .background(AgentOverlayScrollerStyle())
            }
            .scrollIndicators(.automatic)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .onScrollGeometryChange(for: Bool.self) { geo in
                let distance = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                return distance > 80
            } action: { _, newValue in
                withAnimation(.easeOut(duration: 0.15)) { isScrolledFromBottom = newValue }
            }
            .onChange(of: service.messages.count) { _, _ in scrollToBottom(proxy) }
            .onChange(of: service.isStreaming) { _, _ in scrollToBottom(proxy) }
            .overlay(alignment: .bottomTrailing) {
                if isScrolledFromBottom {
                    scrollToBottomButton(proxy: proxy)
                        .padding(.trailing, AppTheme.Spacing.mdLg)
                        .padding(.bottom, AppTheme.Spacing.mdLg)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
        }
    }

    private func scrollToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToBottom(proxy)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                .glassEffect(.regular, in: .circle)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.string("Scroll to latest"))
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = service.streamError {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(verbatim: errorMessage(err))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                if let cta = errorCTA(for: err) {
                    Button(action: cta.action) {
                        Text(cta.title)
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    }
                    .buttonStyle(.capsule(.secondary))
                    .controlSize(.small)
                }
            }
        }
    }

    private struct ErrorCTA {
        let title: String
        let action: () -> Void
    }

    private func errorCTA(for error: AgentServiceError?) -> ErrorCTA? {
        guard let error else { return nil }
        switch error {
        case .unavailable:
            return ErrorCTA(title: L10n.string("Open Settings")) {
                SettingsWindowController.shared.show(tab: .agent)
            }
        case .refusal, .upstream:
            return nil
        }
    }

    private func errorMessage(_ error: AgentServiceError) -> String {
        switch error {
        case .upstream(let message):
            message
        case .unavailable(let model):
            model.provider?.chatPresentation.unavailableMessage
                ?? L10n.string("This agent is not available.")
        case .refusal:
            L10n.string("The selected model refused this request. Revise the prompt and try again.")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.canStream {
            VStack(spacing: AppTheme.Spacing.smMd) {
                Text(L10n.string("Ask anything, or start with:"))
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .multilineTextAlignment(.center)
                VStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(Self.starterPrompts) { starterPrompt in
                        AgentStarterPromptButton(starterPrompt: starterPrompt) {
                            Analytics.capture(.agentStarterPromptClicked, properties: [
                                "starter_prompt": starterPrompt.id,
                            ])
                            populatePrompt(starterPrompt.prompt)
                        }
                    }
                }
            }
        } else {
            missingKeyState
        }
    }

    private var missingKeyState: some View {
        VStack(spacing: AppTheme.Spacing.mdLg) {
            Text(L10n.string("Add an OpenRouter or Google AI API key to use AI chat."))
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .multilineTextAlignment(.center)

            Button(action: { SettingsWindowController.shared.show(tab: .agent) }) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "gearshape")
                    Text(L10n.string("Open Settings"))
                }
                .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if service.isStreaming {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo("streaming-indicator", anchor: .bottom)
            }
        } else if let last = service.messages.last {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }

    private var footer: some View {
        @Bindable var service = editor.agentService
        return VStack(spacing: AppTheme.Spacing.sm) {
            if !service.canStream && !service.messages.isEmpty {
                missingKeyState
            }
            AgentInputBox(
                draft: $service.draft,
                mentions: $service.mentions,
                isSending: service.isStreaming,
                canSend: canSend,
                onSend: submit,
                onCancel: { service.cancel() }
            ) {
                modelPicker
                reasoningEffortPicker
                byokIndicator
            }
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.bottom, AppTheme.Spacing.mdLg)
        .padding(.top, AppTheme.Spacing.xs)
        .frame(maxWidth: Layout.chatColumnMax)
        .frame(maxWidth: .infinity)
    }

    private func submit() {
        guard canSend else { return }
        service.send(text: service.draft, mentions: service.mentions)
        service.draft = ""
        service.mentions.removeAll()
    }

    private func populatePrompt(_ prompt: String) {
        service.draft = prompt
        service.mentions.removeAll()
    }
}

private struct AgentOverlayScrollerStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> AgentOverlayScrollerProbe {
        AgentOverlayScrollerProbe()
    }

    func updateNSView(_ nsView: AgentOverlayScrollerProbe, context: Context) {
        nsView.apply()
    }
}

private final class AgentOverlayScrollerProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    func apply() {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? NSScrollView {
                scrollView.scrollerStyle = .overlay
                scrollView.autohidesScrollers = true
                return
            }
            ancestor = current.superview
        }
    }
}

private struct AgentStarterPrompt: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let prompt: String
}

private struct AgentStarterPromptButton: View {
    let starterPrompt: AgentStarterPrompt
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: starterPrompt.systemImage)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                Text(starterPrompt.title)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverHighlight(cornerRadius: AppTheme.Radius.lg)
            .glassEffect(.regular, in: .rect(cornerRadius: AppTheme.Radius.lg))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(L10n.string("Fill prompt"))
    }
}

private struct PanelTab: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(isActive ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
                Text(verbatim: displayTitle)
                    .font(.system(
                        size: AppTheme.FontSize.xs,
                        weight: isActive ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium
                    ))
                    .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .documentTabChrome(isActive: isActive, isCloseable: true, onClose: onClose)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var displayTitle: String {
        title.count > 20 ? String(title.prefix(20)) + "…" : title
    }
}

@MainActor
private extension AgentProvider {
    var chatPresentation: (byokLabel: String, byokHelp: String, unavailableMessage: String) {
        switch self {
        case .openRouter:
            (
                L10n.string("using OpenRouter API key"),
                L10n.string("Streaming through your OpenRouter API key"),
                L10n.string("Add an OpenRouter API key in Settings › Agent to use this model.")
            )
        case .google:
            (
                L10n.string("using Google AI API key"),
                L10n.string("Streaming through your Google AI API key"),
                L10n.string("Add a Google AI API key in Settings › Agent to use this model.")
            )
        }
    }
}
