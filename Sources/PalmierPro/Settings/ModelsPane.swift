import SwiftUI

struct ModelsPane: View {
    private var prefs = ModelPreferences.shared
    private var catalog = ModelCatalog.shared
    private var account = AccountService.shared

    @State private var query = ""

    private struct Row: Identifiable {
        let id: String
        let displayName: String
        let paidOnly: Bool
        let providerIconKey: String?
    }

    private struct Section: Identifiable {
        let id: String
        let title: String
        let rows: [Row]
    }

    private func isLocked(_ row: Row) -> Bool { row.paidOnly && !account.isPaid }

    private var sections: [Section] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        func prepare(_ rows: [Row]) -> [Row] {
            let matched = q.isEmpty ? rows : rows.filter { $0.displayName.lowercased().contains(q) }
            // Available models first, locked (paid-only) ones grouped at the bottom.
            return matched.filter { !isLocked($0) } + matched.filter { isLocked($0) }
        }
        return [
            Section(id: "image", title: L10n.string("Image"),
                    rows: prepare(catalog.image.map { row(for: $0.entry) })),
            Section(id: "video", title: L10n.string("Video"),
                    rows: prepare(catalog.video.map { row(for: $0.entry) })),
            Section(id: "audio", title: L10n.string("Audio"),
                    rows: prepare(catalog.audio.map { row(for: $0.entry) })),
        ].filter { !$0.rows.isEmpty }
    }

    private func row(for entry: CatalogEntry) -> Row {
        Row(
            id: entry.id,
            displayName: entry.displayName,
            paidOnly: entry.paidOnly,
            providerIconKey: entry.providerIconKey
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            SettingsSection(title: "Own API Keys") {
                APIKeyField(
                    title: "ElevenLabs API Key",
                    explanation: "Generate speech, sound effects, and music straight from your ElevenLabs account. Billed by ElevenLabs, not in credits. Stored in the macOS Keychain.",
                    linkTitle: "Get ElevenLabs API key",
                    linkURL: URL(string: "https://elevenlabs.io/app/settings/api-keys")!,
                    placeholder: "sk_…",
                    load: { ElevenLabsKeychain.load() },
                    save: { ElevenLabsKeychain.save($0) },
                    remove: { ElevenLabsKeychain.delete() }
                )
                APIKeyField(
                    title: "Google AI API Key",
                    explanation: "Generate and edit video and images with Gemini Omni Flash — swap objects, rewrite scenes, and recut footage. Billed by Google, not in credits. Stored in the macOS Keychain.",
                    linkTitle: "Get Google AI API key",
                    linkURL: URL(string: "https://aistudio.google.com/apikey")!,
                    placeholder: "AIza…",
                    load: { GeminiKeychain.load() },
                    save: { GeminiKeychain.save($0) },
                    remove: { GeminiKeychain.delete() }
                )
                APIKeyField(
                    title: "Pexels API Key",
                    explanation: "Browse and import free stock photos and videos from Pexels in the Stock tab. Free key, no billing. Stored in the macOS Keychain.",
                    linkTitle: "Get Pexels API key",
                    linkURL: StockMediaProvider.pexels.keyURL,
                    placeholder: "Pexels key…",
                    load: { StockMediaKeychain.load(provider: .pexels) },
                    save: { StockMediaKeychain.save($0, provider: .pexels) },
                    remove: { StockMediaKeychain.delete(provider: .pexels) }
                )
                APIKeyField(
                    title: "Pixabay API Key",
                    explanation: "Browse and import free stock photos and videos from Pixabay in the Stock tab. Free key, no billing. Stored in the macOS Keychain.",
                    linkTitle: "Get Pixabay API key",
                    linkURL: StockMediaProvider.pixabay.keyURL,
                    placeholder: "Pixabay key…",
                    load: { StockMediaKeychain.load(provider: .pixabay) },
                    save: { StockMediaKeychain.save($0, provider: .pixabay) },
                    remove: { StockMediaKeychain.delete(provider: .pixabay) }
                )
            }

            searchBar

            if sections.isEmpty {
                Text(catalog.isLoaded
                    ? L10n.string("No models match \"\(query)\".")
                    : L10n.string("Loading models…"))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.top, AppTheme.Spacing.lg)
            } else {
                ForEach(sections) { section in
                    sectionView(section)
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField(L10n.string("Search models"), text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(AppTheme.Interaction.fill(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func sectionView(_ section: Section) -> some View {
        SettingsSection(title: section.title) {
            VStack(spacing: 0) {
                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                    modelRow(row)
                    if index < section.rows.count - 1 {
                        Divider().overlay(AppTheme.Border.subtleColor)
                    }
                }
            }
            .padding(.vertical, AppTheme.Spacing.xs)
        }
    }

    @ViewBuilder
    private func modelRow(_ row: Row) -> some View {
        let locked = isLocked(row)
        HStack(spacing: AppTheme.Spacing.md) {
            if let iconKey = row.providerIconKey {
                ProviderLogo(iconKey: iconKey, size: AppTheme.IconSize.md)
                    .opacity(locked ? AppTheme.Opacity.medium : AppTheme.Opacity.opaque)
            }
            Text(row.displayName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(locked ? AppTheme.Text.tertiaryColor : AppTheme.Text.primaryColor)
            Spacer(minLength: AppTheme.Spacing.lg)
            if locked {
                Button(L10n.string("Subscribe")) {
                    SettingsWindowController.shared.show(tab: .account)
                }
                .buttonStyle(.capsule(.secondary))
            } else {
                Toggle(String(), isOn: Binding(
                    get: { prefs.isEnabled(row.id) },
                    set: { prefs.setEnabled(row.id, $0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .accessibilityLabel(row.displayName)
            }
        }
        .padding(.vertical, AppTheme.Spacing.smMd)
    }
}
