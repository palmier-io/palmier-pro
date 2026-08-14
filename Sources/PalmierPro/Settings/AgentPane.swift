import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                SettingsSection(title: L10n.string("AI Chat")) {
                    apiKeySection
                }
                SettingsSection(title: L10n.string("Custom Models")) {
                    customProviderSection
                }
                SettingsSection(title: L10n.string("Integrations")) {
                    mcpSection
                }
            }
            .padding(.vertical, AppTheme.Spacing.md)
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            Text(L10n.string("Use your own API key for AI chat. Stored in the macOS Keychain."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
            APIKeySettingRow(provider: .anthropic)
            APIKeySettingRow(provider: .openAI)
        }
    }

    // MARK: - Custom providers

    @State private var customProviders: [CustomAgentProvider] = []
    @State private var showAddForm = false

    private var customProviderSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(L10n.string("Add OpenAI-compatible API endpoints (e.g. DeepSeek, Groq, Ollama, Together AI)."))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(customProviders) { provider in
                CustomProviderRow(provider: provider) {
                    removeCustomProvider(provider)
                }
            }

            if showAddForm {
                CustomProviderForm { provider in
                    addCustomProvider(provider)
                    showAddForm = false
                } onCancel: {
                    showAddForm = false
                }
            }

            Button {
                showAddForm = true
            } label: {
                Label(L10n.string("Add Custom Model"), systemImage: "plus")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .disabled(showAddForm)
        }
        .onAppear { loadCustomProviders() }
    }

    private func loadCustomProviders() {
        Task {
            customProviders = await CustomAgentProvider.loadAll()
        }
    }

    private func addCustomProvider(_ provider: CustomAgentProvider) {
        customProviders.append(provider)
        Task { await CustomAgentProvider.saveAll(customProviders) }
    }

    private func removeCustomProvider(_ provider: CustomAgentProvider) {
        customProviders.removeAll { $0.id == provider.id }
        Task { await CustomAgentProvider.saveAll(customProviders) }
    }

    // MARK: - MCP server

    private var mcpSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            mcpHeader
            mcpStatusRow
        }
    }

    private var mcpHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(L10n.string("MCP Server"))
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Lets external clients like Cursor, Claude Desktop, Claude Code, and Codex edit your timeline."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: openInstructions) {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Text(L10n.string("Setup instructions"))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.link)
                }
                .buttonStyle(.plain)
                .fixedSize()
                .pointerStyle(.link)
            }
        }
    }

    private var mcpStatusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill((appState.mcpService?.isRunning ?? false) ? AppTheme.Status.successColor : AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.Spacing.smMd, height: AppTheme.Spacing.smMd)

                if appState.mcpService?.isRunning ?? false {
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xxs) {
                        Text(L10n.string("Running on"))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Text(verbatim: "127.0.0.1:\(String(MCPService.port))")
                            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                    }
                } else {
                    Text(L10n.string("Stopped"))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .font(.system(size: AppTheme.FontSize.sm))

            Spacer()

            Toggle(
                String(),
                isOn: Binding(
                    get: { (appState.mcpService?.isRunning ?? false) },
                    set: { appState.setMCPEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel(L10n.string("MCP Server"))
        }
        .padding(.top, AppTheme.Spacing.xs)
    }

    private func openInstructions() {
        HelpWindowController.shared.show(tab: .mcp)
    }
}

private struct APIKeySettingRow: View {
    let provider: AgentProvider

    @State private var hasKey = false
    @State private var maskedKey = ""
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            HStack(spacing: AppTheme.Spacing.sm) {
                field
                trailingControl
            }
        }
        .onAppear(perform: refresh)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Text(provider.apiKeyPresentation.title)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Button(action: openConsole) {
                HStack(spacing: AppTheme.Spacing.xxs) {
                    Text(provider.apiKeyPresentation.getKeyTitle)
                    Image(systemName: "arrow.up.right")
                        .font(.system(
                            size: AppTheme.FontSize.xs,
                            weight: AppTheme.FontWeight.semibold
                        ))
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Accent.link)
            }
            .buttonStyle(.plain)
            .fixedSize()
            .pointerStyle(.link)
        }
    }

    private var field: some View {
        SecureField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .focused($isFocused)
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .onSubmit(save)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        isFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin
                    )
            )
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: isFocused)
    }

    @ViewBuilder
    private var trailingControl: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button(L10n.string("Save"), action: save)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey {
            Button(action: remove) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help(L10n.string("Remove API key"))
        }
    }

    private var placeholder: String {
        hasKey ? maskedKey : provider.apiKeyPresentation.placeholder
    }

    private func openConsole() {
        NSWorkspace.shared.open(
            provider.apiKeyPresentation.consoleURL, configuration: .init(), completionHandler: nil
        )
    }

    private func refresh() {
        Task {
            applyKey(await provider.loadAPIKey())
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        draft = ""
        isFocused = false
        let provider = provider
        Task {
            await provider.setAPIKey(key)
            applyKey(key)
        }
    }

    private func remove() {
        draft = ""
        let provider = provider
        Task {
            await provider.setAPIKey(nil)
            applyKey("")
        }
    }

    private func applyKey(_ key: String) {
        hasKey = !key.isEmpty
        maskedKey = key.count > 4
            ? String(repeating: "\u{2022}", count: 36) + key.suffix(4)
            : String(repeating: "\u{2022}", count: 32)
    }
}

@MainActor
private extension AgentProvider {
    var apiKeyPresentation: (
        title: String, getKeyTitle: String, placeholder: String, consoleURL: URL
    ) {
        switch self {
        case .anthropic:
            (
                L10n.string("Anthropic API Key"),
                L10n.string("Get Anthropic API key"),
                "sk-ant-…",
                URL(string: "https://console.anthropic.com/settings/keys")!
            )
        case .openAI:
            (
                L10n.string("OpenAI API Key"),
                L10n.string("Get OpenAI API key"),
                "sk-…",
                URL(string: "https://platform.openai.com/api-keys")!
            )
        }
    }
}

private struct CustomProviderRow: View {
    let provider: CustomAgentProvider
    let onRemove: () -> Void

    @State private var hasKey = false
    @State private var maskedKey = ""
    @State private var draft = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text(verbatim: provider.name)
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text(verbatim: provider.baseURL.absoluteString)
                            .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .lineLimit(1)
                        Text(verbatim: "·")
                            .foregroundStyle(AppTheme.Text.mutedColor)
                        Text(verbatim: provider.modelID)
                            .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .help(L10n.string("Remove"))
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .onSubmit(save)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(
                                isFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                                lineWidth: AppTheme.BorderWidth.thin
                            )
                    )

                let trimmed = draft.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    Button(L10n.string("Save"), action: save)
                        .buttonStyle(.capsule(.prominent, size: .regular))
                        .controlSize(.large)
                }
            }
        }
        .onAppear(perform: refresh)
    }

    private var placeholder: String {
        hasKey ? maskedKey : "sk-…"
    }

    private func refresh() {
        Task {
            let key = await provider.loadAPIKey()
            applyKey(key)
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        draft = ""
        isFocused = false
        let provider = provider
        Task {
            await provider.setAPIKey(key)
            applyKey(key)
        }
    }

    private func applyKey(_ key: String) {
        hasKey = !key.isEmpty
        maskedKey = key.count > 4
            ? String(repeating: "\u{2022}", count: 36) + key.suffix(4)
            : String(repeating: "\u{2022}", count: 32)
    }
}

private struct CustomProviderForm: View {
    let onSave: (CustomAgentProvider) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var urlString = ""
    @State private var modelID = ""
    @FocusState private var focusedField: Field?

    private enum Field { case name, url, model }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(L10n.string("Display name"))
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                TextField("e.g. DeepSeek", text: $name)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .name)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                    )
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(L10n.string("API base URL"))
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                TextField("https://api.deepseek.com/v1/responses", text: $urlString)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .url)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                    )
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(L10n.string("Model ID"))
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                TextField("e.g. deepseek-chat", text: $modelID)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .model)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                    )
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Button(L10n.string("Cancel"), action: onCancel)
                    .buttonStyle(.capsule(.secondary, size: .regular))
                Spacer()
                Button(L10n.string("Add"), action: submit)
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .disabled(!isValid)
            }
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.faint))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
        .onAppear { focusedField = .name }
    }

    private var isValid: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        let u = urlString.trimmingCharacters(in: .whitespaces)
        let m = modelID.trimmingCharacters(in: .whitespaces)
        return !n.isEmpty && !m.isEmpty && URL(string: u) != nil
    }

    private func submit() {
        let n = name.trimmingCharacters(in: .whitespaces)
        let u = urlString.trimmingCharacters(in: .whitespaces)
        let m = modelID.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: u), !n.isEmpty, !m.isEmpty else { return }
        onSave(CustomAgentProvider(name: n, baseURL: url, modelID: m))
    }
}
