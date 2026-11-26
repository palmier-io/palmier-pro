import AppKit
import SwiftUI

struct MCPInstructionsPane: View {
    @State private var claudeInstallError: String?

    private var mcpEndpoint: String { MCPConnectionConfiguration.endpoint }

    private var claudeCodeCommand: String {
        MCPConnectionConfiguration.claudeCodeCommand
    }

    private var codexCommand: String {
        MCPConnectionConfiguration.codexCommand
    }

    private var cursorJSONConfig: String {
        """
        {
          "mcpServers": {
            "compositor-pro": {
              "type": "http",
              "url": "\(mcpEndpoint)"
            }
          }
        }
        """
    }

    private var cursorDeepLink: URL? {
        let config: [String: String] = ["type": "http", "url": mcpEndpoint]
        guard
            let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
            let encoded = data.base64EncodedString().addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return nil }
        return URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=compositor-pro&config=\(encoded)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                Text(L10n.string("Connect an external agent to inspect and edit the open Compositor Pro project."))
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsGroup(title: L10n.string("Server URL")) {
                    endpointRow
                }

                SettingsGroup(title: L10n.string("Connect an agent")) {
                    agentList
                }
            }
            .frame(maxWidth: AppTheme.Settings.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.bottom, AppTheme.Spacing.xxl)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .alert(
            L10n.string("Unable to open Claude Desktop"),
            isPresented: Binding(
                get: { claudeInstallError != nil },
                set: { if !$0 { claudeInstallError = nil } }
            )
        ) {
            Button(L10n.string("Dismiss")) { claudeInstallError = nil }
        } message: {
            Text(verbatim: claudeInstallError ?? L10n.string("Try again."))
        }
    }

    private var endpointRow: some View {
        MCPConnectionCodeBlock(
            content: mcpEndpoint,
            fontSize: AppTheme.FontSize.sm,
            foreground: AppTheme.Text.primaryColor,
            verticalPadding: AppTheme.Spacing.smMd
        )
    }

    private var agentList: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            claudeDesktopSection
            agentDivider
            claudeCodeSection
            agentDivider
            codexSection
            agentDivider
            antigravitySection
            agentDivider
            cursorSection
        }
    }

    private var cursorSection: some View {
        agentSection(
            .cursor,
            name: "Cursor",
            description: L10n.string("Install the Compositor Pro MCP server in Cursor."),
            action: (L10n.string("Install in Cursor"), openCursor)
        ) {
            ManualFallback(
                intro: L10n.string("Add this configuration to ~/.cursor/mcp.json."),
                code: cursorJSONConfig
            )
        }
    }

    private var claudeDesktopSection: some View {
        agentSection(
            .claude,
            name: "Claude Desktop",
            description: L10n.string("Install the bundled Compositor Pro connector."),
            action: (L10n.string("Install in Claude Desktop"), openClaudeDesktopBundle)
        ) {
            EmptyView()
        }
    }

    private var claudeCodeSection: some View {
        agentSection(
            .claude,
            name: "Claude Code",
            description: L10n.string("Run this command once in Terminal.")
        ) {
            MCPConnectionCodeBlock(content: claudeCodeCommand)
        }
    }

    private var codexSection: some View {
        agentSection(
            .codex,
            name: "Codex",
            description: L10n.string("Run this command once in Terminal.")
        ) {
            MCPConnectionCodeBlock(content: codexCommand)
        }
    }

    private var antigravitySection: some View {
        agentSection(
            nil,
            name: MCPExternalClient.antigravity.name,
            description: L10n.string(key: MCPExternalClient.antigravity.setupDescription)
        ) {
            Text(verbatim: MCPConnectionConfiguration.antigravityConfigPath)
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .textSelection(.enabled)
            MCPConnectionCodeBlock(content: MCPConnectionConfiguration.antigravityConfiguration)
        }
    }

    private var agentDivider: some View {
        Divider().overlay(AppTheme.Border.subtleColor)
    }

    private func agentSection<Details: View>(
        _ agent: SkillExternalAgent?,
        name: String,
        description: String,
        action: (label: String, perform: () -> Void)? = nil,
        @ViewBuilder details: () -> Details
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .center, spacing: AppTheme.Spacing.md) {
                agentIdentity(agent: agent, name: name, description: description)
                if let action {
                    Spacer(minLength: AppTheme.Spacing.md)
                    externalAction(action.label, action: action.perform)
                }
            }
            details()
        }
        .padding(.vertical, AppTheme.Spacing.mdLg)
    }

    private func agentIdentity(agent: SkillExternalAgent?, name: String, description: String) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            if let agent {
                ExternalAgentLogo(agent: agent, size: AppTheme.IconSize.lgXl)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Accent.primary)
                    .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
            }

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(name)
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(description)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func externalAction(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Text(label)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.regular))
            }
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
            .foregroundStyle(AppTheme.Accent.link)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .pointerStyle(.link)
    }

    private func openCursor() {
        guard let cursorDeepLink else { return }
        NSWorkspace.shared.open(cursorDeepLink, configuration: .init(), completionHandler: nil)
    }

    private func openClaudeDesktopBundle() {
        guard let bundleURL = claudeDesktopBundleURL else {
            claudeInstallError = "The Compositor Pro connector could not be found. Reinstall Compositor Pro, then try again."
            return
        }
        guard let claudeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") else {
            claudeInstallError = "Install Claude Desktop, then try again."
            return
        }

        NSWorkspace.shared.open(
            [bundleURL],
            withApplicationAt: claudeURL,
            configuration: .init()
        ) { _, error in
            guard error != nil else { return }
            Task { @MainActor in
                claudeInstallError = "Claude Desktop could not open the Compositor Pro connector. Update Claude Desktop, then try again."
            }
        }
    }

    private var claudeDesktopBundleURL: URL? {
        BundledResource.url("compositor-pro.mcpb")
    }
}

private struct ManualFallback: View {
    let intro: String
    let code: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Button(action: toggle) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.regular))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(L10n.string("Manual setup"))
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
                }
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text(intro)
                        .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    MCPConnectionCodeBlock(content: code)
                }
            }
        }
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: AppTheme.Anim.hover)) {
            expanded.toggle()
        }
    }
}

#Preview {
    MCPInstructionsPane()
        .frame(width: AppTheme.Settings.contentMaxWidth, height: AppTheme.Settings.skillDetailMinHeight)
        .background(AppTheme.Background.surfaceColor)
}
