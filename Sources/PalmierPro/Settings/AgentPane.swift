import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared
    @State private var mcpBindHost: String = MCPService.bindHostPreference
    @State private var mcpBearerToken: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: L10n.string("AI Chat")) {
                apiKeySection
            }
            SettingsSection(title: L10n.string("Integrations")) {
                mcpSection
            }
        }
        .onAppear(perform: refreshMCPSettings)
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
            mcpNetworkAccessRow
            mcpConnectionBox
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
                        Text(verbatim: mcpServerAddress)
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

    private var mcpNetworkAccessRow: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Allow access from local network")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text("Requires the bearer token for every LAN request.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { mcpLANAccessEnabled },
                    set: { setMCPLANAccess($0) }
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

    private var mcpConnectionBox: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            mcpValueRow(label: "Connection URL", value: mcpConnectionURL)

            if mcpLANAccessEnabled {
                Divider().overlay(AppTheme.Border.subtleColor)
                mcpValueRow(label: "Bearer token", value: mcpBearerToken)
                Button("Regenerate Token", action: regenerateMCPToken)
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.large)
            }
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

    private func mcpValueRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(label)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .textCase(.uppercase)
                Spacer()
                mcpCopyButton(value: value)
            }

            Text(value)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func mcpCopyButton(value: String) -> some View {
        Button(action: { copyToPasteboard(value) }) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help("Copy")
    }

    private var mcpLANAccessEnabled: Bool {
        MCPHTTPServer.requiresBearerToken(bindHost: mcpBindHost)
    }

    private var mcpServerAddress: String {
        "\(mcpConnectionHost):\(MCPService.port)"
    }

    private var mcpConnectionURL: String {
        "http://\(mcpServerAddress)/mcp"
    }

    private var mcpConnectionHost: String {
        mcpBindHost == MCPService.lanBindHost ? MCPService.connectionHost : mcpBindHost
    }

    private func refreshMCPSettings() {
        mcpBindHost = MCPService.bindHostPreference
        mcpBearerToken = mcpLANAccessEnabled ? MCPService.bearerTokenPreference : ""
    }

    private func setMCPLANAccess(_ enabled: Bool) {
        let host = enabled ? MCPService.lanBindHost : MCPService.loopbackBindHost
        mcpBindHost = host
        appState.setMCPHost(host)
        mcpBearerToken = enabled ? MCPService.bearerTokenPreference : ""
    }

    private func regenerateMCPToken() {
        mcpBearerToken = appState.regenerateMCPToken()
    }

    private func copyToPasteboard(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
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
