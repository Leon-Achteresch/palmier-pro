import SwiftUI

struct StockTab: View {
    @Environment(EditorViewModel.self) private var editor

    @State private var query = ""
    @State private var kind: StockMediaKind = .video
    @State private var provider: StockMediaProvider?
    @State private var configuredProviders: [StockMediaProvider] = []
    @State private var providersLoaded = false
    @State private var items: [StockMediaItem] = []
    @State private var totalResults = 0
    @State private var page = 1
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var importedIds: Set<String> = []
    @State private var searchTask: Task<Void, Never>?
    @State private var searchGeneration = 0

    var body: some View {
        VStack(spacing: 0) {
            if providersLoaded, configuredProviders.isEmpty {
                noKeyState
            } else {
                controls
                resultsArea
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await refreshProviders() }
        .onReceive(NotificationCenter.default.publisher(for: .stockMediaAPIKeyChanged)) { _ in
            Task { await refreshProviders() }
        }
        .onChange(of: kind) { _, _ in restartSearch() }
        .onChange(of: provider) { _, _ in restartSearch() }
        .onDisappear { searchTask?.cancel() }
    }

    private var controls: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                TextField("Search free stock media", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .onSubmit { restartSearch() }
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(Color.white.opacity(AppTheme.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
            )

            HStack(spacing: AppTheme.Spacing.sm) {
                Picker("", selection: $kind) {
                    Text("Videos").tag(StockMediaKind.video)
                    Text("Photos").tag(StockMediaKind.photo)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                Spacer(minLength: 0)

                if configuredProviders.count > 1 {
                    Picker("", selection: $provider) {
                        ForEach(configuredProviders, id: \.self) { p in
                            Text(p.displayName).tag(Optional(p))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                } else if let provider {
                    Text(provider.displayName)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.top, AppTheme.Spacing.md)
        .padding(.bottom, AppTheme.Spacing.sm)
    }

    @ViewBuilder
    private var resultsArea: some View {
        if let errorMessage {
            statusText(errorMessage)
        } else if items.isEmpty {
            statusText(
                isLoading
                    ? "Searching…"
                    : "Free, royalty-free photos and videos.\nSearch to get started."
            )
        } else {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 140), spacing: AppTheme.Spacing.sm)],
                    spacing: AppTheme.Spacing.sm
                ) {
                    ForEach(items) { item in
                        StockItemTile(
                            item: item,
                            imported: importedIds.contains(item.id),
                            importAction: { importItem(item) }
                        )
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.md)

                if items.count < totalResults {
                    Button(isLoading ? "Loading…" : "Load More") { loadMore() }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .disabled(isLoading)
                        .padding(.vertical, AppTheme.Spacing.md)
                }

                if let provider {
                    Text(provider.licenseNote)
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .padding(.bottom, AppTheme.Spacing.md)
                }
            }
        }
    }

    private var noKeyState: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: AppTheme.FontSize.display))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text("Browse free stock photos and videos from Pexels and Pixabay. Add a free API key to start.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .multilineTextAlignment(.center)
            Button("Add API Key…") {
                SettingsWindowController.shared.show(tab: .models)
            }
            .buttonStyle(.capsule(.prominent, size: .regular))
        }
        .padding(AppTheme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .multilineTextAlignment(.center)
            .padding(AppTheme.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func refreshProviders() async {
        let keys = await Task.detached(priority: .utility) {
            StockMediaProvider.allCases.filter { StockMediaKeychain.load(provider: $0) != nil }
        }.value
        configuredProviders = keys
        providersLoaded = true
        if let provider, keys.contains(provider) { return }
        provider = keys.first
    }

    private func restartSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runSearch(query: trimmed, page: 1, append: false)
    }

    private func loadMore() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runSearch(query: trimmed, page: page + 1, append: true)
    }

    private func runSearch(query: String, page requestedPage: Int, append: Bool) {
        guard let provider else { return }
        searchTask?.cancel()
        searchGeneration += 1
        let generation = searchGeneration
        let kind = kind
        isLoading = true
        errorMessage = nil
        if !append {
            items = []
            totalResults = 0
        }
        searchTask = Task { @MainActor in
            defer { if generation == searchGeneration { isLoading = false } }
            let apiKey = await Task.detached(priority: .utility) {
                StockMediaKeychain.load(provider: provider)
            }.value
            guard generation == searchGeneration, !Task.isCancelled else { return }
            guard let apiKey else {
                errorMessage = "No \(provider.displayName) API key configured."
                return
            }
            do {
                let result = try await StockMediaAPI.search(
                    provider: provider, kind: kind, query: query,
                    page: requestedPage, apiKey: apiKey
                )
                guard generation == searchGeneration, !Task.isCancelled else { return }
                items = append ? items + result.items.filter { item in !items.contains(where: { $0.id == item.id }) } : result.items
                totalResults = result.totalResults
                page = requestedPage
                if items.isEmpty {
                    errorMessage = "No \(kind == .photo ? "photos" : "videos") found for \"\(query)\"."
                }
            } catch {
                guard generation == searchGeneration, !Task.isCancelled else { return }
                errorMessage = (error as? StockMediaAPI.APIError)?.message ?? error.localizedDescription
            }
        }
    }

    private func importItem(_ item: StockMediaItem) {
        guard !importedIds.contains(item.id) else { return }
        let asset = editor.importRemoteMedia(
            url: item.downloadURL,
            type: item.kind == .photo ? .image : .video,
            fileExtension: item.fileExtension,
            name: item.defaultName
        )
        if asset != nil {
            importedIds.insert(item.id)
        }
    }
}

private struct StockItemTile: View {
    let item: StockMediaItem
    let imported: Bool
    let importAction: () -> Void

    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            thumbnail
            if !item.author.isEmpty {
                Text(item.author)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { importAction() }
        .contextMenu {
            Button("Import") { importAction() }
                .disabled(imported)
            if let pageURL = item.pageURL {
                Button("Open on \(item.provider.displayName)") {
                    NSWorkspace.shared.open(pageURL)
                }
            }
        }
        .help(imported ? "Imported" : "Click to import")
    }

    private var thumbnail: some View {
        AsyncImage(url: item.thumbnailURL) { phase in
            switch phase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                Image(systemName: "photo")
                    .font(.system(size: AppTheme.FontSize.lg))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            default:
                Color.white.opacity(AppTheme.Opacity.subtle)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        )
        .overlay(alignment: .bottomTrailing) {
            if let duration = item.durationSeconds {
                Text(Self.durationLabel(duration))
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppTheme.Spacing.xs)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .background(Capsule().fill(Color.black.opacity(AppTheme.Opacity.strong)))
                    .padding(AppTheme.Spacing.xs)
            }
        }
        .overlay(alignment: .topTrailing) {
            if imported {
                badge(systemName: "checkmark.circle.fill")
            } else if hovered {
                badge(systemName: "arrow.down.circle.fill")
            }
        }
    }

    private func badge(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: AppTheme.FontSize.lg))
            .foregroundStyle(.white, Color.black.opacity(AppTheme.Opacity.strong))
            .padding(AppTheme.Spacing.xs)
    }

    private static func durationLabel(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
