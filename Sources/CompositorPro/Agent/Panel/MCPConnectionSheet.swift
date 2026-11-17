import SwiftUI

struct ConnectAgentButton: View {
    @Environment(EditorViewModel.self) private var editor
    var compact = false
    @State private var isPresented = false

    var body: some View {
        Button { isPresented = true } label: {
            if compact {
                Image(systemName: "link")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                    .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            } else {
                Label(L10n.string("Connect agent"), systemImage: "link")
                    .titlebarCapsule(
                        fill: AppTheme.Accent.primary.opacity(AppTheme.Opacity.muted),
                        foreground: AppTheme.Accent.primary
                    )
            }
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(L10n.string("Connect an agent"))
        .help(L10n.string("Connect Codex, Claude Code, or Antigravity"))
        .sheet(isPresented: $isPresented) {
            MCPConnectionSheet(projectId: editor.projectId, agent: editor.agentService) { harness, modelID in
                guard editor.agentService.setLocalModelID(modelID, for: harness) else { return false }
                editor.agentService.selectLocalHarness(harness)
                editor.agentPanelVisible = true
                return true
            }
                .appLocalization()
        }
    }
}

struct MCPConnectionSheet: View {
    let projectId: String?
    let agent: AgentService
    let useAgent: @MainActor (LocalAgentHarness, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @Bindable private var appState = AppState.shared
    @State private var selectedClient = MCPExternalClient.codex
    @State private var startRequested = false
    @State private var useInChat = true
    @State private var refreshID = UUID()
    @State private var detectingAgents = true
    @State private var localModelID = ""
    @State private var invalidModelID = false

    private var service: MCPService? { appState.mcpService }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            HStack {
                Text(L10n.string("Connect agent"))
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
                Button(L10n.string("Done")) { dismiss() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .keyboardShortcut(.cancelAction)
            }
            .padding(AppTheme.Spacing.xlXxl)

            Divider().overlay(AppTheme.Border.subtleColor)

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xlXxl) {
                    Text(useInChat
                         ? L10n.string("Use your agent's existing account directly in Compositor chat. The app connects the project tools automatically.")
                         : L10n.string("Use your agent's existing account to inspect and edit this project. Keep Compositor Pro open while it works."))
                        .font(.system(size: AppTheme.FontSize.smMd))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)

                    Picker(L10n.string("Connection"), selection: $useInChat) {
                        Text(L10n.string("Use in chat")).tag(true)
                        Text(L10n.string("Connect another app")).tag(false)
                    }
                    .pickerStyle(.segmented)
                    clientPicker
                    if useInChat {
                        localAgentSection
                    } else {
                        serverSection
                        setupSection
                        inspectionSection
                    }
                }
                .padding(AppTheme.Spacing.xlXxl)
            }
        }
        .frame(width: AppTheme.Workspace.connectionSheetWidth, height: AppTheme.Workspace.connectionSheetHeight)
        .background(AppTheme.Background.surfaceColor)
        .task(id: selectedClient) {
            localModelID = agent.localModelID(for: selectedClient.localHarness) ?? ""
            invalidModelID = false
        }
        .task(id: refreshID) {
            detectingAgents = true
            await agent.reloadLocalAgents().value
            guard !Task.isCancelled else { return }
            detectingAgents = false
        }
        .task(id: startRequested) {
            guard startRequested, !Task.isCancelled else { return }
            await appState.setMCPEnabled(true)
            guard !Task.isCancelled else { return }
            startRequested = false
        }
    }

    private var localAgentSection: some View {
        let harness = selectedClient.localHarness
        let installed = agent.localAgentExecutables[harness] != nil
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack {
                Text(verbatim: harness.name)
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                Spacer()
                Text(detectingAgents ? L10n.string("Checking…") : (installed ? L10n.string("Installed") : L10n.string("Not installed")))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(installed ? AppTheme.Status.successColor : AppTheme.Text.secondaryColor)
                Button(L10n.string("Refresh")) { refreshID = UUID() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .disabled(detectingAgents)
            }
            Text(L10n.string("Uses the account from your \(harness.name) CLI. Runs are billed to that account."))
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Model ID (optional)"))
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                TextField(L10n.string("Use CLI default"), text: $localModelID)
                    .textFieldStyle(.roundedBorder)
                if invalidModelID {
                    Text(L10n.string("Enter a model ID with at most 256 bytes and no control characters."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Status.errorColor)
                }
            }
            if !installed {
                Text(L10n.string("Install once in Terminal, then refresh:"))
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                MCPConnectionCodeBlock(content: harness.installCommand)
            }
            Text(L10n.string("Sign in once in Terminal if needed:"))
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            MCPConnectionCodeBlock(content: harness.signInCommand)
            HStack {
                Link(L10n.string("Agent documentation"), destination: harness.documentationURL)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.link)
                Spacer()
                Button(L10n.string("Use in chat")) {
                    guard useAgent(harness, localModelID) else { invalidModelID = true; return }
                    dismiss()
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .disabled(!installed || detectingAgents)
            }
        }
        .foregroundStyle(AppTheme.Text.primaryColor)
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Local server"))
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                Spacer()
                Circle()
                    .fill(service?.isRunning == true ? AppTheme.Status.successColor : AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.Spacing.smMd, height: AppTheme.Spacing.smMd)
                Text(serverStatus)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                if service?.isRunning != true {
                    Button(L10n.string("Start server")) { startRequested = true }
                        .buttonStyle(.capsule(.secondary, size: .regular))
                        .disabled(startRequested || service?.isStarting == true || service?.state == .stopping)
                }
            }
            .foregroundStyle(AppTheme.Text.primaryColor)

            MCPConnectionCodeBlock(
                content: MCPConnectionConfiguration.endpoint,
                fontSize: AppTheme.FontSize.sm,
                foreground: AppTheme.Text.primaryColor,
                verticalPadding: AppTheme.Spacing.smMd
            )

            if let error = service?.startupError {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(L10n.string("Could not start MCP server. Quit other Compositor Pro instances, then try again."))
                    Text(verbatim: error)
                }
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Status.errorColor)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var serverStatus: String {
        switch service?.state {
        case .running: L10n.string("Ready")
        case .starting: L10n.string("Starting…")
        case .stopping: L10n.string("Stopping…")
        case .failed: L10n.string("Unavailable")
        case .stopped, nil: L10n.string("Stopped")
        }
    }

    private var clientPicker: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ForEach(MCPExternalClient.allCases) { client in
                Button { selectedClient = client } label: {
                    VStack(spacing: AppTheme.Spacing.sm) {
                        clientArtwork(client)
                        Text(verbatim: client.name)
                            .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    }
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .frame(maxWidth: .infinity, minHeight: AppTheme.Workspace.connectionCardMinHeight)
                    .background(
                        selectedClient == client
                            ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint)
                            : AppTheme.Background.raisedColor,
                        in: RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                            .strokeBorder(
                                selectedClient == client ? AppTheme.Accent.primary : AppTheme.Border.subtleColor,
                                lineWidth: AppTheme.BorderWidth.thin
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedClient == client ? .isSelected : [])
            }
        }
    }

    @ViewBuilder
    private func clientArtwork(_ client: MCPExternalClient) -> some View {
        switch client {
        case .codex: ExternalAgentLogo(agent: .codex, size: AppTheme.IconSize.mdLg)
        case .claudeCode: ExternalAgentLogo(agent: .claude, size: AppTheme.IconSize.mdLg)
        case .antigravity:
            Image(systemName: "sparkles")
                .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Accent.primary)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
        }
    }

    private var setupSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(verbatim: selectedClient.name)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(L10n.string(key: selectedClient.setupDescription))
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
            if selectedClient == .antigravity {
                Text(verbatim: MCPConnectionConfiguration.antigravityConfigPath)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .textSelection(.enabled)
            }
            MCPConnectionCodeBlock(content: MCPConnectionConfiguration.setupCode(for: selectedClient))
            Link(L10n.string("Client documentation"), destination: selectedClient.documentationURL)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Accent.link)
        }
    }

    private var inspectionSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(L10n.string("Try the connection"))
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Text(L10n.string("Send this in your agent after setup to inspect the selected project."))
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            MCPConnectionCodeBlock(content: MCPConnectionConfiguration.inspectionPrompt(projectId: projectId))
        }
    }
}
