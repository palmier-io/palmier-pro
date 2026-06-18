import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared
    @State private var hasKey = false
    @State private var maskedKey = ""
    @State private var draft = ""
    @State private var showKeyField = false
    @FocusState private var isFocused: Bool

    private let codexURL = URL(string: "https://developers.openai.com/codex/")!

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
            Text("Agent Providers")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Text("Choose Anthropic API or local Codex CLI from agent chat model picker.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

            anthropicStatusRow

            providerStatusRow(
                title: "Codex CLI",
                detail: CodexCLIClient.isAvailable ? "Connected local Codex CLI" : "Not connected. Install or open Codex app.",
                isConnected: CodexCLIClient.isAvailable,
                actionTitle: CodexCLIClient.isAvailable ? nil : "Connect Codex",
                action: { NSWorkspace.shared.open(codexURL, configuration: .init(), completionHandler: nil) }
            )
        }
    }

    private var anthropicStatusRow: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            HStack(spacing: AppTheme.Spacing.sm) {
                statusDot(hasKey)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                    Text("Anthropic API")
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(hasKey ? "Connected with saved API key" : "Not connected. Add API key below.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }

                Spacer()

                if hasKey {
                    Button(action: remove) {
                        Image(systemName: "trash")
                            .font(.system(size: AppTheme.FontSize.md))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.large)
                    .help("Remove API key")
                } else if !showKeyField {
                    Button("Add key") {
                        showKeyField = true
                        DispatchQueue.main.async { isFocused = true }
                    }
                    .buttonStyle(.capsule(.secondary))
                    .controlSize(.small)
                }
            }

            if showKeyField && !hasKey {
                keyField
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

    private func providerStatusRow(
        title: String,
        detail: String,
        isConnected: Bool,
        actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            statusDot(isConnected)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(detail)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            Spacer()

            if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.capsule(.secondary))
                    .controlSize(.small)
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

    private func statusDot(_ isConnected: Bool) -> some View {
        Circle()
            .fill(isConnected ? Color.green : AppTheme.Text.mutedColor)
            .frame(width: 8, height: 8)
    }

    private var keyField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            SecureField(hasKey ? maskedKey : "sk-ant-...", text: $draft)
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

            if !draft.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Save", action: save)
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.large)
            }
        }
    }

    private func refresh() {
        let key = AnthropicKeychain.load() ?? ""
        hasKey = !key.isEmpty
        maskedKey = mask(key)
        if hasKey {
            showKeyField = false
        }
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        AnthropicKeychain.save(key)
        draft = ""
        showKeyField = false
        isFocused = false
        refresh()
    }

    private func remove() {
        AnthropicKeychain.delete()
        draft = ""
        showKeyField = false
        refresh()
    }

    private func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "\u{2022}", count: 32) }
        return String(repeating: "\u{2022}", count: 36) + key.suffix(4)
    }

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
            statusDot(appState.mcpService?.isRunning ?? false)

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

            Spacer()

            Toggle(
                "",
                isOn: Binding(
                    get: { appState.mcpService?.isRunning ?? false },
                    set: { appState.setMCPEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
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
