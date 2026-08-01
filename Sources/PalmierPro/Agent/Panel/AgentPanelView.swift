import SwiftTerm
import SwiftUI

struct AgentPanelView: View {
    @Environment(EditorViewModel.self) var editor

    private static let starterPrompts: [AgentStarterPrompt] = [
        AgentStarterPrompt(
            title: "Generate an AI video",
            systemImage: "sparkles",
            prompt: "Generate an AI video of "
        ),
        AgentStarterPrompt(
            title: "Generate B-roll",
            systemImage: "film",
            prompt: "Generate B-roll for my timeline. Inspect the current edit, identify sections that would benefit from cutaways, generate suitable B-roll, and place it where it supports the story."
        ),
        AgentStarterPrompt(
            title: "Create a letterbox opening",
            systemImage: "camera.aperture",
            prompt: "Create a cinematic opening for my timeline. Use the first visual clip, animate a subtle letterbox matte with top and bottom crop keyframes, starting from crop to uncrop,and keep the motion restrained and polished."
        ),
        AgentStarterPrompt(
            title: "Add captions to my timeline",
            systemImage: "captions.bubble",
            prompt: "Add captions to my timeline. Transcribe spoken audio in timeline clips, build readable caption phrases on word boundaries, and place them as text clips aligned to the edit."
        ),
        AgentStarterPrompt(
            title: "Create a voiceover",
            systemImage: "waveform",
            prompt: "Create a voiceover for my timeline. Draft concise narration for the current edit, generate the voiceover, and add it to an audio track aligned with the timeline."
        ),
        AgentStarterPrompt(
            title: "Generate music and sync to my timeline",
            systemImage: "music.note",
            prompt: "Score my timeline with music. Inspect the edit's mood and pacing, generate music for the full timeline, and place it on an audio track aligned to the edit."
        ),
        AgentStarterPrompt(
            title: "Organize my media into structured folders",
            systemImage: "folder",
            prompt: "Organize my media into structured folders. Review all assets, create clearly named folders by role, scene, or type, move assets into them, and rename generic files when useful. Don't delete anything or change the timeline."
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
            ZStack(alignment: .top) {
                if let terminalView {
                    AgentTerminalView(terminal: terminalView)
                        .padding(.top, Layout.panelHeaderHeight)
                } else {
                    messageList
                }
                floatingTabBar
            }
            if terminalView == nil { footer }
        }
        .background(AppTheme.Background.surfaceColor)
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
                        HStack(spacing: AppTheme.Spacing.xxs) {
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
            .glassEffect(.regular, in: Rectangle())
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(AppTheme.Border.subtleColor)
                    .frame(height: AppTheme.BorderWidth.hairline)
            }
        }
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
        } primaryAction: {
            activeTerminal = nil
            service.newChat()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focusable(false)
        .help("New chat or terminal")
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
        .help("Chat history")
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

    private var modelPicker: some View {
        Menu {
            ForEach(service.availableModels, id: \.self) { m in
                Button(m.displayName) { service.model = m }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(service.effectiveModel.displayName)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Model routed through OpenRouter")
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
                .padding(.top, Layout.panelHeaderHeight + AppTheme.Spacing.sm)
                .padding(.bottom, AppTheme.Spacing.smMd)
                .frame(maxWidth: Layout.chatColumnMax)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.never)
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
        .help("Scroll to latest")
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let err = service.streamError {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(err.localizedDescription)
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

    private func errorCTA(for error: AgentStreamError?) -> ErrorCTA? {
        guard let error else { return nil }
        switch error {
        case .missingKey:
            return ErrorCTA(title: "Add API key") {
                SettingsWindowController.shared.show(tab: .agent)
            }
        case .upstream:
            return nil
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.canStream {
            VStack(spacing: AppTheme.Spacing.smMd) {
                Text("Ask anything, or start with:")
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .multilineTextAlignment(.center)
                VStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(Self.starterPrompts) { starterPrompt in
                        AgentStarterPromptButton(starterPrompt: starterPrompt) {
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
            Button(action: { SettingsWindowController.shared.show(tab: .agent) }) {
                Label("Add OpenRouter API key", systemImage: "key.fill")
                    .font(.system(size: AppTheme.FontSize.mdLg, weight: .semibold))
            }
            .buttonStyle(.capsule(.prominent, size: .regular))

            Text("AI chat runs on your own OpenRouter key. No Palmier account needed.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .multilineTextAlignment(.center)
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

private struct AgentStarterPrompt: Identifiable {
    let id = UUID()
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
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(AppTheme.Background.raisedColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
            )
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help("Fill prompt")
    }
}

private struct PanelTab: View {
    let title: String
    let systemImage: String
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: systemImage)
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                    .foregroundStyle(isActive ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
                Text(title)
                    .font(.system(size: AppTheme.FontSize.xs, weight: isActive ? .semibold : .regular))
                    .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: Layout.chatTabTitleMax, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .opacity(hovering ? AppTheme.Opacity.opaque : 0)
            }
            .padding(.leading, AppTheme.Spacing.sm)
            .padding(.trailing, AppTheme.Spacing.xs)
            .frame(height: AppTheme.IconSize.md)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(isActive ? AppTheme.Background.prominentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(title)
    }
}
