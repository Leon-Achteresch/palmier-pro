import SwiftUI

struct AgentModelPicker: View {
    let models: [AgentModel]
    let selectedId: String
    let isLoading: Bool
    let onSelect: (AgentModel) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [AgentModel] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return models }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || $0.id.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider().opacity(AppTheme.Opacity.faint)
            list
        }
        .frame(width: 320)
        .glassEffect(.clear, in: .rect(cornerRadius: AppTheme.Radius.md))
        .onAppear { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField("Search models", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs))
                .focused($searchFocused)
            if isLoading {
                ProgressView()
                    .controlSize(.mini)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    @ViewBuilder
    private var list: some View {
        if filtered.isEmpty {
            Text(isLoading ? "Loading models…" : "No models match")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .padding(AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { model in
                        row(model)
                    }
                }
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 360)
        }
    }

    private func row(_ model: AgentModel) -> some View {
        let isSelected = model.id == selectedId
        return Button {
            onSelect(model)
        } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(model.displayName)
                        .font(.system(
                            size: AppTheme.FontSize.xs,
                            weight: isSelected ? .semibold : .regular
                        ))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                    Text(model.id)
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        .foregroundStyle(AppTheme.Accent.primary)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .background(isSelected ? AppTheme.Accent.primary.opacity(0.15) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
