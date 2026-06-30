import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared

    @State private var provider: AgentProviderPreference = .palmier

    @State private var anthropicHasKey: Bool = false
    @State private var anthropicMaskedKey: String = ""
    @State private var anthropicDraft: String = ""

    @State private var openAIBaseURL: String = ""
    @State private var savedOpenAIBaseURL: String = ""
    @State private var openAIModel: String = ""
    @State private var savedOpenAIModel: String = ""
    @State private var openAIHasKey: Bool = false
    @State private var openAIMaskedKey: String = ""
    @State private var openAIKeyDraft: String = ""

    @FocusState private var focusedField: FocusedField?

    private enum FocusedField: Hashable {
        case anthropicKey
        case openAIBaseURL
        case openAIModel
        case openAIKey
    }

    private let anthropicConsoleURL = URL(string: "https://console.anthropic.com/settings/keys")!
    private let openAIKeysURL = URL(string: "https://platform.openai.com/api-keys")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            providerSection
            Divider().overlay(AppTheme.Border.subtleColor)
            anthropicSection
            Divider().overlay(AppTheme.Border.subtleColor)
            openAICompatibleSection
            Divider().overlay(AppTheme.Border.subtleColor)
            mcpSection
        }
        .onAppear(perform: refresh)
    }

    // MARK: - Provider

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            sectionHeader(
                title: "Agent Backend",
                subtitle: "Choose where the in-app agent streams model responses."
            )

            Picker("", selection: $provider) {
                ForEach(AgentProviderPreference.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: provider) { _, newValue in
                AgentProviderPreference.save(newValue)
            }
        }
    }

    // MARK: - Anthropic

    private var anthropicSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            sectionHeader(
                title: "Anthropic API Key",
                subtitle: "Use your own Anthropic key for the AI chat. Stored in your macOS Keychain.",
                linkTitle: "Get Anthropic API key",
                linkURL: anthropicConsoleURL
            )

            HStack(spacing: AppTheme.Spacing.sm) {
                secureField(
                    placeholder: anthropicPlaceholder,
                    text: $anthropicDraft,
                    focused: .anthropicKey,
                    onSubmit: saveAnthropic
                )
                anthropicTrailingControl
            }
        }
    }

    private var anthropicPlaceholder: String {
        anthropicHasKey ? anthropicMaskedKey : "sk-ant-..."
    }

    @ViewBuilder
    private var anthropicTrailingControl: some View {
        let trimmed = anthropicDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Button("Save", action: saveAnthropic)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if anthropicHasKey {
            Button(action: removeAnthropicKey) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help("Remove API key")
        }
    }

    private func saveAnthropic() {
        let key = anthropicDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        anthropicDraft = ""
        focusedField = nil
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                AnthropicKeychain.save(key)
                AgentProviderPreference.save(.anthropic)
            }.value
            provider = .anthropic
            applyAnthropicKey(key)
        }
    }

    private func removeAnthropicKey() {
        anthropicDraft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                AnthropicKeychain.delete()
            }.value
            applyAnthropicKey("")
        }
    }

    // MARK: - OpenAI Compatible

    private var openAICompatibleSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            sectionHeader(
                title: "OpenAI-Compatible Endpoint",
                subtitle: "Use a Chat Completions-compatible endpoint. API keys are optional and stored in your macOS Keychain.",
                linkTitle: "OpenAI API keys",
                linkURL: openAIKeysURL
            )

            textField(
                label: "Base URL",
                placeholder: "https://api.openai.com/v1",
                text: $openAIBaseURL,
                focused: .openAIBaseURL,
                monospaced: true,
                onSubmit: saveOpenAICompatible
            )

            textField(
                label: "Model",
                placeholder: "model name",
                text: $openAIModel,
                focused: .openAIModel,
                monospaced: true,
                onSubmit: saveOpenAICompatible
            )

            HStack(spacing: AppTheme.Spacing.sm) {
                secureField(
                    placeholder: openAIKeyPlaceholder,
                    text: $openAIKeyDraft,
                    focused: .openAIKey,
                    onSubmit: saveOpenAICompatible
                )
                openAITrailingControls
            }
        }
    }

    private var openAIKeyPlaceholder: String {
        openAIHasKey ? openAIMaskedKey : "Optional API key"
    }

    private var openAIIsDirty: Bool {
        openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) != savedOpenAIBaseURL ||
        openAIModel.trimmingCharacters(in: .whitespacesAndNewlines) != savedOpenAIModel ||
        !openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var openAIHasSavedConfig: Bool {
        !savedOpenAIBaseURL.isEmpty || !savedOpenAIModel.isEmpty || openAIHasKey
    }

    @ViewBuilder
    private var openAITrailingControls: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if openAIIsDirty {
                Button("Save", action: saveOpenAICompatible)
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.large)
            }
            if openAIHasKey && openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button(action: removeOpenAIKey) {
                    Image(systemName: "trash")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.large)
                .help("Remove API key")
            }
            if openAIHasSavedConfig {
                Button("Clear", action: clearOpenAICompatible)
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.large)
            }
        }
    }

    private func saveOpenAICompatible() {
        let baseURL = openAIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = openAIModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = openAIKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        focusedField = nil
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                OpenAICompatibleSettings.save(baseURL: baseURL, model: model)
                if !key.isEmpty {
                    OpenAICompatibleKeychain.save(key)
                }
                if OpenAICompatibleEndpoint.normalizedURL(from: baseURL) != nil && !model.isEmpty {
                    AgentProviderPreference.save(.openAICompatible)
                }
            }.value
            savedOpenAIBaseURL = baseURL
            savedOpenAIModel = model
            openAIBaseURL = baseURL
            openAIModel = model
            openAIKeyDraft = ""
            if !key.isEmpty { applyOpenAIKey(key) }
            if OpenAICompatibleEndpoint.normalizedURL(from: baseURL) != nil && !model.isEmpty {
                provider = .openAICompatible
            }
        }
    }

    private func removeOpenAIKey() {
        openAIKeyDraft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                OpenAICompatibleKeychain.delete()
            }.value
            applyOpenAIKey("")
        }
    }

    private func clearOpenAICompatible() {
        openAIBaseURL = ""
        openAIModel = ""
        openAIKeyDraft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                OpenAICompatibleSettings.clear()
                if AgentProviderPreference.stored == .openAICompatible {
                    AgentProviderPreference.save(.palmier)
                }
            }.value
            savedOpenAIBaseURL = ""
            savedOpenAIModel = ""
            applyOpenAIKey("")
            if provider == .openAICompatible {
                provider = .palmier
            }
        }
    }

    // MARK: - Shared fields

    private func sectionHeader(
        title: String,
        subtitle: String,
        linkTitle: String? = nil,
        linkURL: URL? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(subtitle)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                if let linkTitle, let linkURL {
                    Button(action: { NSWorkspace.shared.open(linkURL, configuration: .init(), completionHandler: nil) }) {
                        HStack(spacing: AppTheme.Spacing.xxs) {
                            Text(linkTitle)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                        }
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Accent.primary)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
        }
    }

    private func textField(
        label: String,
        placeholder: String,
        text: Binding<String>,
        focused: FocusedField,
        monospaced: Bool = false,
        onSubmit: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .focused($focusedField, equals: focused)
                .font(.system(size: AppTheme.FontSize.sm, design: monospaced ? .monospaced : .default))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .onSubmit(onSubmit)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .background(inputBackground(isFocused: focusedField == focused))
                .overlay(inputBorder(isFocused: focusedField == focused))
                .animation(.easeOut(duration: AppTheme.Anim.hover), value: focusedField == focused)
        }
    }

    private func secureField(
        placeholder: String,
        text: Binding<String>,
        focused: FocusedField,
        onSubmit: @escaping () -> Void
    ) -> some View {
        SecureField(placeholder, text: text)
            .textFieldStyle(.plain)
            .focused($focusedField, equals: focused)
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .onSubmit(onSubmit)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(inputBackground(isFocused: focusedField == focused))
            .overlay(inputBorder(isFocused: focusedField == focused))
            .animation(.easeOut(duration: AppTheme.Anim.hover), value: focusedField == focused)
    }

    private func inputBackground(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .fill(Color.black.opacity(isFocused ? AppTheme.Opacity.moderate : AppTheme.Opacity.muted))
    }

    private func inputBorder(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(
                isFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                lineWidth: AppTheme.BorderWidth.thin
            )
    }

    private func refresh() {
        Task { @MainActor in
            let snapshot = await Task.detached(priority: .utility) {
                let anthropicKey = AnthropicKeychain.load() ?? ""
                let openAIKey = OpenAICompatibleKeychain.load() ?? ""
                let baseURL = OpenAICompatibleSettings.savedBaseURLString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let model = OpenAICompatibleSettings.savedModel
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let provider = AgentProviderPreference.defaultProvider(
                    hasAnthropicKey: !anthropicKey.isEmpty,
                    hasOpenAICompatibleConfig: OpenAICompatibleEndpoint.normalizedURL(from: baseURL) != nil && !model.isEmpty
                )
                return (anthropicKey, openAIKey, baseURL, model, provider)
            }.value
            applyAnthropicKey(snapshot.0)
            applyOpenAIKey(snapshot.1)
            savedOpenAIBaseURL = snapshot.2
            openAIBaseURL = snapshot.2
            savedOpenAIModel = snapshot.3
            openAIModel = snapshot.3
            provider = snapshot.4
        }
    }

    private func applyAnthropicKey(_ key: String) {
        anthropicHasKey = !key.isEmpty
        anthropicMaskedKey = mask(key)
    }

    private func applyOpenAIKey(_ key: String) {
        openAIHasKey = !key.isEmpty
        openAIMaskedKey = mask(key)
    }

    private func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "\u{2022}", count: 32) }
        return String(repeating: "\u{2022}", count: 36) + key.suffix(4)
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
            Text("MCP Server")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Lets external clients like Cursor, Claude Desktop, Claude Code, and Codex edit your timeline.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: openInstructions) {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Text("Setup instructions")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    }
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.primary)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
    }

    private var mcpStatusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Circle()
                    .fill((appState.mcpService?.isRunning ?? false) ? Color.green : AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.Spacing.smMd, height: AppTheme.Spacing.smMd)

                if appState.mcpService?.isRunning ?? false {
                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.xxs) {
                        Text("Running on ")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Text("127.0.0.1:\(String(MCPService.port))")
                            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                    }
                } else {
                    Text("Stopped")
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .font(.system(size: AppTheme.FontSize.sm))

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { (appState.mcpService?.isRunning ?? false) },
                    set: { appState.setMCPEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.black.opacity(AppTheme.Opacity.muted))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    private func openInstructions() {
        HelpWindowController.shared.show(tab: .mcp)
    }
}
