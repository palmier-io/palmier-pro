import SwiftUI

struct ModelsPane: View {
    private var prefs = ModelPreferences.shared
    private var catalog = ModelCatalog.shared
    private var account = AccountService.shared
    @Bindable private var customModels = CustomAgentModelStore.shared

    @State private var query = ""
    @State private var isAddingCustomModel = false

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

    private var filteredCustomModels: [CustomAgentModel] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return customModels.models }
        return customModels.models.filter {
            $0.displayName.lowercased().contains(q) || $0.modelID.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            searchBar
            customChatModelsSection

            if sections.isEmpty && filteredCustomModels.isEmpty {
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
        .sheet(isPresented: $isAddingCustomModel) {
            AddCustomAgentModelSheet()
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

    private var customChatModelsSection: some View {
        SettingsSection(title: L10n.string("AI Chat")) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text(L10n.string("Add custom Anthropic or OpenAI model IDs for BYOK chat."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                if filteredCustomModels.isEmpty {
                    Text(L10n.string("No custom chat models yet."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(filteredCustomModels.enumerated()), id: \.element.id) { index, model in
                            customModelRow(model)
                            if index < filteredCustomModels.count - 1 {
                                Divider().overlay(AppTheme.Border.subtleColor)
                            }
                        }
                    }
                }

                Button {
                    isAddingCustomModel = true
                } label: {
                    Text(L10n.string("Add Model"))
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
            }
        }
    }

    private func customModelRow(_ model: CustomAgentModel) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            providerIcon(for: model.provider)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(verbatim: model.displayName)
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(verbatim: model.modelID)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer(minLength: AppTheme.Spacing.lg)
            Text(verbatim: model.provider.displayName)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Button {
                customModels.remove(id: model.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.plain)
            .help(L10n.string("Remove custom model"))
        }
        .padding(.vertical, AppTheme.Spacing.smMd)
    }

    @ViewBuilder
    private func providerIcon(for provider: AgentProvider) -> some View {
        switch provider {
        case .anthropic:
            ExternalAgentLogo(agent: .claude, size: AppTheme.IconSize.md)
        case .openAI:
            ProviderLogo(iconKey: "openai", size: AppTheme.IconSize.md)
        }
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

private struct AddCustomAgentModelSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable private var customModels = CustomAgentModelStore.shared

    @State private var provider: AgentProvider = .openAI
    @State private var modelID = ""
    @State private var displayName = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            Text(L10n.string("Add Custom Model"))
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                fieldLabel(L10n.string("Provider"))
                Picker(selection: $provider) {
                    Text(verbatim: AgentProvider.anthropic.displayName).tag(AgentProvider.anthropic)
                    Text(verbatim: AgentProvider.openAI.displayName).tag(AgentProvider.openAI)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                fieldLabel(L10n.string("Model ID"))
                TextField(provider == .anthropic ? "claude-sonnet-4-5" : "gpt-4.1", text: $modelID)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(fieldBackground)
                    .overlay(fieldBorder)

                fieldLabel(L10n.string("Display Name"))
                TextField(L10n.string("Optional"), text: $displayName)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(fieldBackground)
                    .overlay(fieldBorder)
            }

            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Spacer()
                Button(L10n.string("Cancel")) { dismiss() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                Button(L10n.string("Add")) { add() }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 420)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(verbatim: title)
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
    }

    private var fieldBorder: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
    }

    private func add() {
        do {
            _ = try customModels.add(
                provider: provider,
                modelID: modelID,
                displayName: displayName
            )
            dismiss()
        } catch {
            if let modelError = error as? CustomAgentModelError,
               let key = modelError.errorDescription {
                errorMessage = L10n.string(key: key)
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
