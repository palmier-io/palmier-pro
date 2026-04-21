import AppKit
import SwiftUI

struct MCPInstructionsPane: View {
    private var serverURL: String { "http://127.0.0.1:\(MCPService.port)" }

    private var claudeCodeCommand: String {
        "claude mcp add --transport http palmier-pro \(serverURL)"
    }

    private var clientJSONConfig: String {
        """
        {
          "mcpServers": {
            "palmier-pro": {
              "url": "\(serverURL)"
            }
          }
        }
        """
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                overviewSection

                urlSection

                claudeCodeSection

                desktopSection

                tipSection
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Sections

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeading("Overview")
            Text("Palmier Pro exposes your open project as an MCP server. Point any MCP-capable client at the URL below to let it edit the timeline, generate media, and read project state.")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var urlSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Server URL")
            HStack(spacing: 8) {
                Text(serverURL)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                            .stroke(AppTheme.Border.subtleColor, lineWidth: 1)
                    )

                CopyButton(value: serverURL)
                Spacer()
            }
        }
    }

    private var claudeCodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Connect from Claude Code")
            Text("Run this once in your terminal:")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            codeBlock(claudeCodeCommand)
        }
    }

    private var desktopSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("Connect from Claude Desktop or Cursor")
            Text("Add this to your client's MCP config, then restart it:")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            codeBlock(clientJSONConfig)
        }
    }

    private var tipSection: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .padding(.top, 2)
            Text("The MCP server only runs while a project window is open. If your client can't connect, make sure Palmier Pro is running with a project loaded.")
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    // MARK: - Helpers

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .textCase(.uppercase)
            .tracking(0.3)
    }

    private func codeBlock(_ content: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(content)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            CopyButton(value: content)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .stroke(AppTheme.Border.subtleColor, lineWidth: 1)
        )
    }
}

private struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(copied ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                .frame(width: 26, height: 26)
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
