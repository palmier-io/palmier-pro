import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared
    @State private var hasKey: Bool = false
    @State private var maskedKey: String = ""
    @State private var draft: String = ""
    @State private var mcpBindHost: String = MCPService.bindHostPreference
    @State private var mcpBearerToken: String = ""
    @FocusState private var isFocused: Bool

    private let consoleURL = URL(string: "https://console.anthropic.com/settings/keys")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            apiKeySection
            Divider().overlay(AppTheme.Border.subtleColor)
            mcpSection
        }
        .onAppear(perform: refresh)
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header
            keyField
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Anthropic API Key")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Used your own API key for the AI chat. Stored in your macOS Keychain.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: { NSWorkspace.shared.open(consoleURL, configuration: .init(), completionHandler: nil) }) {
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

    private var keyField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            fieldBox
            trailingControl
        }
    }

    private var fieldBox: some View {
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
                    .fill(Color.black.opacity(AppTheme.Opacity.muted))
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

    private var placeholder: String {
        hasKey ? maskedKey : "sk-ant-..."
    }

    @ViewBuilder
    private var trailingControl: some View {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            Button("Save", action: save)
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
            .help("Remove API key")
        }
    }

    private func refresh() {
        refreshMCPSettings()
        Task { @MainActor in
            let key = await Self.loadKey()
            applyKey(key)
        }
    }

    private func applyKey(_ key: String) {
        hasKey = !key.isEmpty
        maskedKey = mask(key)
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        draft = ""
        isFocused = false
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                AnthropicKeychain.save(key)
            }.value
            applyKey(key)
        }
    }

    private func remove() {
        draft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                AnthropicKeychain.delete()
            }.value
            applyKey("")
        }
    }

    private static func loadKey() async -> String {
        await Task.detached(priority: .utility) {
            AnthropicKeychain.load() ?? ""
        }.value
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
            mcpNetworkAccessRow
            mcpConnectionBox
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
                        Text(mcpServerAddress)
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
                    set: setMCPLANAccess
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
