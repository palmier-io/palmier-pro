import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: L10n.string("AI Chat")) {
                apiKeySection
            }
            SettingsSection(title: L10n.string("Integrations")) {
                mcpSection
            }
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
    private let defaults: UserDefaults

    @State private var hasKey = false
    @State private var maskedKey = ""
    @State private var keyDraft = ""
    @State private var baseURLDraft = ""
    @State private var storedBaseURL = ""
    @State private var keySaveFailed = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case apiKey
        case baseURL
    }

    init(provider: AgentProvider, defaults: UserDefaults = .standard) {
        self.provider = provider
        self.defaults = defaults
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            keySection
            if keySaveFailed {
                Text(L10n.string("Could not save API key to the Keychain. Delete any existing Palmier API key items in Keychain Access, then try again."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            baseURLSection
        }
        .onAppear(perform: refresh)
    }

    private var keySection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            HStack(spacing: AppTheme.Spacing.sm) {
                secureField
                keyTrailingControl
            }
        }
    }

    private var baseURLSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(L10n.string("Base URL"))
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            HStack(spacing: AppTheme.Spacing.sm) {
                baseURLField
                baseURLTrailingControl
            }
        }
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

    private var secureField: some View {
        SecureField(keyPlaceholder, text: $keyDraft)
            .textFieldStyle(.plain)
            .focused($focusedField, equals: .apiKey)
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .onSubmit(saveKey)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        focusedField == .apiKey
                            ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin
                    )
            )
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: focusedField == .apiKey)
    }

    private var baseURLField: some View {
        TextField(provider.defaultBaseURLString, text: $baseURLDraft)
            .textFieldStyle(.plain)
            .focused($focusedField, equals: .baseURL)
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .onSubmit(saveBaseURL)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        focusedField == .baseURL
                            ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                        lineWidth: AppTheme.BorderWidth.thin
                    )
            )
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: focusedField == .baseURL)
    }

    @ViewBuilder
    private var keyTrailingControl: some View {
        let trimmed = keyDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button(L10n.string("Save"), action: saveKey)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey {
            Button(action: removeKey) {
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

    @ViewBuilder
    private var baseURLTrailingControl: some View {
        if baseURLIsDirty {
            Button(L10n.string("Save"), action: saveBaseURL)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if !storedBaseURL.isEmpty {
            Button(action: resetBaseURL) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help(L10n.string("Reset to default base URL"))
        }
    }

    private var keyPlaceholder: String {
        hasKey ? maskedKey : provider.apiKeyPresentation.placeholder
    }

    private var baseURLIsDirty: Bool {
        normalizedBaseURLDraft != storedBaseURL
    }

    private var normalizedBaseURLDraft: String {
        let trimmed = baseURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == provider.defaultBaseURLString ? "" : trimmed
    }

    private func openConsole() {
        NSWorkspace.shared.open(
            provider.apiKeyPresentation.consoleURL, configuration: .init(), completionHandler: nil
        )
    }

    private func refresh() {
        storedBaseURL = AgentBaseURLPreferences.storedString(for: provider, defaults: defaults)
        baseURLDraft = storedBaseURL.isEmpty ? provider.defaultBaseURLString : storedBaseURL
        Task {
            applyKey(await provider.loadAPIKey())
        }
    }

    private func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        keyDraft = ""
        focusedField = nil
        keySaveFailed = false
        let provider = provider
        Task {
            let saved = await provider.setAPIKey(key)
            if saved {
                applyKey(key)
            } else {
                keyDraft = key
                keySaveFailed = true
            }
        }
    }

    private func removeKey() {
        keyDraft = ""
        keySaveFailed = false
        let provider = provider
        Task {
            let removed = await provider.setAPIKey(nil)
            if removed {
                applyKey("")
            } else {
                keySaveFailed = true
            }
        }
    }

    private func saveBaseURL() {
        let value = normalizedBaseURLDraft
        AgentBaseURLPreferences.set(value.isEmpty ? nil : value, for: provider, defaults: defaults)
        storedBaseURL = AgentBaseURLPreferences.storedString(for: provider, defaults: defaults)
        baseURLDraft = storedBaseURL.isEmpty ? provider.defaultBaseURLString : storedBaseURL
        focusedField = nil
    }

    private func resetBaseURL() {
        AgentBaseURLPreferences.set(nil, for: provider, defaults: defaults)
        storedBaseURL = ""
        baseURLDraft = provider.defaultBaseURLString
        focusedField = nil
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
