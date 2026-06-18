import AppKit
import SwiftUI

struct MCPInstructionsPane: View {
    private var serverURL: String { "http://127.0.0.1:\(MCPService.port)" }
    private var mcpEndpoint: String { "\(serverURL)/mcp" }

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
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xlXxl) {
                overviewSection

                urlSection

                cursorSection

                claudeDesktopSection

                claudeCodeSection

                codexSection
            }
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.vertical, AppTheme.Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Sections

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            sectionHeading("Overview")
            Text("Palmier Pro exposes your open project as an MCP server. Connect any MCP clients to let it be your AI assistant.")
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            sectionHeading("Server URL")
            HStack(spacing: AppTheme.Spacing.smMd) {
                Text(mcpEndpoint)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .padding(.horizontal, AppTheme.Spacing.mdLg)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                            .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                    )

                CopyButton(value: mcpEndpoint)
                Spacer()
            }
        }
    }

    private var cursorSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            sectionHeading("Connect from Cursor", prominent: true)
            installButton(label: "Install in Cursor", systemImage: "arrow.down.circle") {
                if let url = cursorDeepLink {
                    NSWorkspace.shared.open(url, configuration: .init(), completionHandler: nil)
                }
            }
            manualFallback(
                intro: "Add this to ~/.cursor/mcp.json in your project:",
                code: cursorJSONConfig
            )
        }
    }

    private var claudeDesktopSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            sectionHeading("Connect from Claude Desktop", prominent: true)
            installButton(label: "Install in Claude Desktop", systemImage: "arrow.down.circle") {
                openClaudeDesktopBundle()
            }
            manualFallback(
                intro: "Open Claude Desktop → Settings → Developer → Edit Config, then merge this into mcpServers:",
                code: claudeDesktopJSONConfig
            )
        }
    }

    private func openClaudeDesktopBundle() {
        guard let resourceURL = Bundle.main.resourceURL else { return }
        let url = resourceURL.appendingPathComponent("palmier-pro.mcpb")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.open(url, configuration: .init(), completionHandler: nil)
    }

    private var claudeCodeSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            sectionHeading("Connect from Claude Code", prominent: true)
            Text("Run this once in your terminal:")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            CodeBlockView(content: claudeCodeCommand)
        }
    }

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            sectionHeading("Connect from Codex", prominent: true)
            Text("Run this once in your terminal:")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            CodeBlockView(content: codexCommand)
        }
    }

    // MARK: - Helpers

    private func sectionHeading(_ text: String, prominent: Bool = false) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
            .foregroundStyle(prominent ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
            .textCase(.uppercase)
            .tracking(0.3)
    }

    private func installButton(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                Text(label)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
            }
            .foregroundStyle(AppTheme.Text.primaryColor)
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                    .stroke(AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium), lineWidth: AppTheme.BorderWidth.thin)
            )
        }
        .buttonStyle(.plain)
    }

    private func manualFallback(intro: String, code: String) -> some View {
        ManualFallback(intro: intro, code: code)
    }
}

private struct CodeBlockView: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
            Text(content)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            CopyButton(value: content)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }
}

private struct ManualFallback: View {
    let intro: String
    let code: String
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Button(action: toggle) {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("Manual setup")
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                }
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text(intro)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    CodeBlockView(content: code)
                }
            }
        }
        .padding(.top, AppTheme.Spacing.xxs)
    }

    private func toggle() {
        withAnimation(.easeInOut(duration: AppTheme.Anim.hover)) {
            expanded.toggle()
        }
    }
}

private struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(copied ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy")
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}

#Preview {
    MCPInstructionsPane()
        .frame(width: 680, height: 560)
        .background(AppTheme.Background.surfaceColor)
}
