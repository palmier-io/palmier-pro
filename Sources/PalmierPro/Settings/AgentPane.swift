import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared
    @State private var hasAnthropicKey: Bool = false
    @State private var anthropicMaskedKey: String = ""
    @State private var anthropicDraft: String = ""
    @FocusState private var isAnthropicFocused: Bool
    @State private var hasOpenRouterKey: Bool = false
    @State private var openRouterMaskedKey: String = ""
    @State private var openRouterDraft: String = ""
    @FocusState private var isOpenRouterFocused: Bool
    @State private var openRouterModelDraft: String = ""

    private let anthropicConsoleURL = URL(string: "https://console.anthropic.com/settings/keys")!
    private let openRouterConsoleURL = URL(string: "https://openrouter.ai/keys")!

    @AppStorage("agentProvider") private var providerRaw: String = AgentProvider.palmier.rawValue
    @AppStorage("openRouterModel") private var openRouterModel: String = "openai/gpt-4o"

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            providerSection
            Divider().overlay(AppTheme.Border.subtleColor)
            mcpSection
        }
        .onAppear(perform: refresh)
    }

    private var providerSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            providerPicker
            providerFields
        }
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("AI Provider")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Picker("Provider", selection: Binding(
                get: { AgentProvider(rawValue: providerRaw) ?? .palmier },
                set: { providerRaw = $0.rawValue }
            )) {
                ForEach(AgentProvider.allCases, id: \.self) { p in
                    Text(p.displayName).tag(p)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var currentProvider: AgentProvider {
        AgentProvider(rawValue: providerRaw) ?? .palmier
    }

    @ViewBuilder
    private var providerFields: some View {
        switch currentProvider {
        case .palmier:
            palmierInfo
        case .anthropic:
            anthropicSection
        case .openRouter:
            openRouterSection
        }
    }

    private var palmierInfo: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Using Palmier's backend for AI chat. Model access depends on your subscription tier.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    // MARK: - Anthropic section

    private var anthropicSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            anthropicHeader
            anthropicKeyField
        }
    }

    private var anthropicHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Anthropic API Key")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Used your own API key for the AI chat. Stored in your macOS Keychain.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: { NSWorkspace.shared.open(anthropicConsoleURL, configuration: .init(), completionHandler: nil) }) {
                    HStack(spacing: 2) {
                        Text("Get Anthropic API key")
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

    private var anthropicKeyField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            SecureField(anthropicPlaceholder, text: $anthropicDraft)
                .textFieldStyle(.plain)
                .focused($isAnthropicFocused)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .onSubmit(saveAnthropic)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.black.opacity(AppTheme.Opacity.muted))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(
                            isAnthropicFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                            lineWidth: AppTheme.BorderWidth.thin
                        )
                )
                .animation(.easeOut(duration: AppTheme.Anim.hover), value: isAnthropicFocused)

            anthropicTrailingControl
        }
    }

    private var anthropicPlaceholder: String {
        hasAnthropicKey ? anthropicMaskedKey : "sk-ant-..."
    }

    @ViewBuilder
    private var anthropicTrailingControl: some View {
        let trimmed = anthropicDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save", action: saveAnthropic)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasAnthropicKey {
            Button(action: removeAnthropic) {
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

    // MARK: - OpenRouter section

    private var openRouterSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            openRouterHeader
            openRouterKeyField
            openRouterModelField
        }
    }

    private var openRouterHeader: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("OpenRouter API Key")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Use any LLM via OpenRouter. Key stored in your macOS Keychain.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: { NSWorkspace.shared.open(openRouterConsoleURL, configuration: .init(), completionHandler: nil) }) {
                    HStack(spacing: 2) {
                        Text("Get OpenRouter API key")
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

    private var openRouterKeyField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            SecureField(openRouterPlaceholder, text: $openRouterDraft)
                .textFieldStyle(.plain)
                .focused($isOpenRouterFocused)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .onSubmit(saveOpenRouter)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.black.opacity(AppTheme.Opacity.muted))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(
                            isOpenRouterFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                            lineWidth: AppTheme.BorderWidth.thin
                        )
                )
                .animation(.easeOut(duration: AppTheme.Anim.hover), value: isOpenRouterFocused)

            openRouterTrailingControl
        }
    }

    private var openRouterPlaceholder: String {
        hasOpenRouterKey ? openRouterMaskedKey : "sk-or-..."
    }

    @ViewBuilder
    private var openRouterTrailingControl: some View {
        let trimmed = openRouterDraft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save", action: saveOpenRouter)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasOpenRouterKey {
            Button(action: removeOpenRouter) {
                Image(systemName: "trash")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .help("Remove OpenRouter API key")
        }
    }

    private var openRouterModelField: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Model")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            HStack(spacing: AppTheme.Spacing.sm) {
                TextField("openai/gpt-4o", text: $openRouterModelDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .onSubmit(saveOpenRouterModel)
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

                let trimmedModel = openRouterModelDraft.trimmingCharacters(in: .whitespaces)
                if !trimmedModel.isEmpty, trimmedModel != openRouterModel {
                    Button("Save", action: saveOpenRouterModel)
                        .buttonStyle(.capsule(.prominent, size: .regular))
                        .controlSize(.large)
                }
            }

            Text("Use any model slug from OpenRouter (e.g. openai/gpt-4o, google/gemini-2.5-pro, anthropic/claude-sonnet-4-6)")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Actions

    private func refresh() {
        let aKey = AnthropicKeychain.load() ?? ""
        hasAnthropicKey = !aKey.isEmpty
        anthropicMaskedKey = mask(aKey)

        let oKey = OpenRouterKeychain.load() ?? ""
        hasOpenRouterKey = !oKey.isEmpty
        openRouterMaskedKey = mask(oKey)

        openRouterModelDraft = openRouterModel
    }

    private func saveAnthropic() {
        let key = anthropicDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        AnthropicKeychain.save(key)
        anthropicDraft = ""
        isAnthropicFocused = false
        refresh()
    }

    private func removeAnthropic() {
        AnthropicKeychain.delete()
        anthropicDraft = ""
        refresh()
    }

    private func saveOpenRouter() {
        let key = openRouterDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        OpenRouterKeychain.save(key)
        openRouterDraft = ""
        isOpenRouterFocused = false
        refresh()
    }

    private func removeOpenRouter() {
        OpenRouterKeychain.delete()
        openRouterDraft = ""
        refresh()
    }

    private func saveOpenRouterModel() {
        let m = openRouterModelDraft.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return }
        openRouterModel = m
        refresh()
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
                    HStack(spacing: 2) {
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
                    .frame(width: 8, height: 8)

                if appState.mcpService?.isRunning ?? false {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
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
