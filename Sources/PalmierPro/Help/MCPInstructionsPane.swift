import AppKit
import SwiftUI

struct MCPInstructionsPane: View {
    @State private var claudeInstallError: String?

    private var mcpEndpoint: String { "http://127.0.0.1:\(MCPService.port)/mcp" }

    private var claudeCodeCommand: String {
        "claude mcp add --transport http palmier-pro \(mcpEndpoint)"
    }

    private var codexCommand: String {
        "codex mcp add palmier-pro --url \(mcpEndpoint)"
    }

    private var cursorJSONConfig: String {
        """
        {
          "mcpServers": {
            "palmier-pro": {
              "type": "http",
              "url": "\(mcpEndpoint)"
            }
          }
        }
        """
    }

    private var claudeDesktopJSONConfig: String {
        """
        {
          "mcpServers": {
            "palmier-pro": {
              "command": "npx",
              "args": [
                "-y",
                "mcp-remote",
                "\(mcpEndpoint)",
                "--allow-http",
                "--transport",
                "http-only"
              ]
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
        return URL(string: "cursor://anysphere.cursor-deeplink/mcp/install?name=palmier-pro&config=\(encoded)")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
                Text("Connect an external agent to inspect and edit the open Palmier Pro project.")
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                SettingsGroup(title: "Server URL") {
                    endpointRow
                }

                SettingsGroup(title: "Connect an agent") {
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
            "Unable to open Claude Desktop",
            isPresented: Binding(
                get: { claudeInstallError != nil },
                set: { if !$0 { claudeInstallError = nil } }
            )
        ) {
            Button("Dismiss") { claudeInstallError = nil }
        } message: {
            Text(claudeInstallError ?? "Use manual setup instead.")
        }
    }

    private var endpointRow: some View {
        CodeBlockView(
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
            cursorSection
        }
    }

    private var cursorSection: some View {
        agentSection(
            .cursor,
            name: "Cursor",
            description: "Install the Palmier Pro MCP server in Cursor.",
            action: ("Install in Cursor", openCursor)
        ) {
            ManualFallback(
                intro: "Add this configuration to ~/.cursor/mcp.json.",
                code: cursorJSONConfig
            )
        }
    }

    private var claudeDesktopSection: some View {
        agentSection(
            .claude,
            name: "Claude Desktop",
            description: "Install the bundled Palmier Pro connector.",
            action: ("Install in Claude Desktop", openClaudeDesktopBundle)
        ) {
            ManualFallback(
                intro: "In Claude Desktop, open Settings › Developer › Edit Config, then add this configuration to mcpServers.",
                code: claudeDesktopJSONConfig
            )
        }
    }

    private var claudeCodeSection: some View {
        agentSection(
            .claude,
            name: "Claude Code",
            description: "Run this command once in Terminal."
        ) {
            CodeBlockView(content: claudeCodeCommand)
        }
    }

    private var codexSection: some View {
        agentSection(
            .codex,
            name: "Codex",
            description: "Run this command once in Terminal."
        ) {
            CodeBlockView(content: codexCommand)
        }
    }

    private var agentDivider: some View {
        Divider().overlay(AppTheme.Border.subtleColor)
    }

    private func agentSection<Details: View>(
        _ agent: SkillExternalAgent,
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

    private func agentIdentity(agent: SkillExternalAgent, name: String, description: String) -> some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ExternalAgentLogo(agent: agent, size: AppTheme.IconSize.lgXl)

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
            claudeInstallError = "The Palmier Pro connector could not be found. Use manual setup instead."
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
                claudeInstallError = "Claude Desktop could not open the Palmier Pro connector. Use manual setup instead."
            }
        }
    }

    private var claudeDesktopBundleURL: URL? {
        BundledResource.url("palmier-pro.mcpb")
    }
}

private struct CodeBlockView: View {
    let content: String
    var fontSize = AppTheme.FontSize.xs
    var foreground = AppTheme.Text.secondaryColor
    var verticalPadding = AppTheme.Spacing.md

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
            Text(content)
                .font(.system(size: fontSize, weight: AppTheme.FontWeight.regular, design: .monospaced))
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            CopyButton(value: content)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, verticalPadding)
        .themedSurface(AppTheme.Background.raisedColor, cornerRadius: AppTheme.Radius.sm)
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
                    Text("Manual setup")
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
                    CodeBlockView(content: code)
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

private struct CopyButton: View {
    private static let feedbackDuration: Duration = .seconds(1.4)

    let value: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(copied ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy")
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: Self.feedbackDuration)
            copied = false
        }
    }
}

#Preview {
    MCPInstructionsPane()
        .frame(width: AppTheme.Settings.contentMaxWidth, height: AppTheme.Settings.skillDetailMinHeight)
        .background(AppTheme.Background.surfaceColor)
}
