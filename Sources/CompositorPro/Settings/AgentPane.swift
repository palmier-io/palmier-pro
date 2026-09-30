import AppKit
import SwiftUI

struct AgentPane: View {
    @Bindable private var appState = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: L10n.string("AI Chat")) {
                apiKeySection
                CustomEndpointSettingSection()
            }
            SettingsSection(title: L10n.string("Integrations")) {
                mcpSection
            }
        }
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
                        Text(verbatim: "127.0.0.1:\(String(MCPService.port))")
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
            consoleLink
        }
    }

    @ViewBuilder
    private var consoleLink: some View {
        if let consoleURL = provider.apiKeyPresentation.consoleURL {
            Button(action: { openConsole(consoleURL) }) {
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

    private func openConsole(_ url: URL) {
        NSWorkspace.shared.open(url, configuration: .init(), completionHandler: nil)
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
        title: String, getKeyTitle: String, placeholder: String, consoleURL: URL?
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
        case .custom:
            (
                L10n.string("Custom Endpoint API Key"),
                "",
                L10n.string("Optional for localhost"),
                nil
            )
        }
    }
}

/// Owns its own draft state so the settings list stays cheap to type-check, and so a failed
/// save never leaves the agent service holding a half-applied endpoint.
private struct CustomEndpointSettingSection: View {
    @State private var models: [CustomAgentModel] = []
    @State private var editing: CustomAgentModel?
    @State private var isAdding = false
    @State private var name = ""
    @State private var baseURL = ""
    @State private var modelID = ""
    @State private var apiKey = ""
    /// The key as last read from the Keychain, so an untouched field can be told apart from a
    /// deliberately emptied one.
    @State private var loadedKey = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            title
            explanation
            if !models.isEmpty { existingModels }
            if isAdding || editing != nil { editor }
            addButton
            errorMessage
        }
        .onAppear(perform: load)
    }

    private var title: some View {
        Text(L10n.string("Custom Models"))
            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.primaryColor)
    }

    private var explanation: some View {
        Text(L10n.string("Add any OpenAI-compatible model. Each keeps its own URL and key, so a local model and a hosted gateway can run side by side."))
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var existingModels: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ForEach(models) { model in
                HStack(spacing: AppTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                        Text(verbatim: model.displayTitle)
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        if let subtitle = model.displaySubtitle {
                            Text(verbatim: subtitle)
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                        }
                        Text(verbatim: model.baseURL.absoluteString)
                            .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: AppTheme.Spacing.sm)
                    Button(action: { beginEdit(model) }) {
                        Image(systemName: "pencil")
                            .font(.system(size: AppTheme.FontSize.md))
                            .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .help(L10n.string("Edit model"))
                    Button(action: { remove(model) }) {
                        Image(systemName: "trash")
                            .font(.system(size: AppTheme.FontSize.md))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .help(L10n.string("Remove model"))
                }
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            field(placeholder: L10n.string("Name (optional)"), text: $name)
            field(placeholder: "http://localhost:11434/v1", text: $baseURL)
            field(placeholder: "qwen3-coder:30b", text: $modelID)
            apiKeyField
            HStack(spacing: AppTheme.Spacing.sm) {
                Button(editing == nil ? L10n.string("Add Model") : L10n.string("Save"), action: save)
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .controlSize(.large)
                    .disabled(!canSave)
                Button(L10n.string("Cancel")) { cancel() }
                    .buttonStyle(.capsule(.secondary, size: .regular))
                    .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var apiKeyField: some View {
        let isLoopback = CustomModelStore.normalizedBaseURL(baseURL)
            .map { CustomAgentModel(baseURL: $0, modelID: "").allowsMissingAPIKey } ?? false
        Group {
            if isLoopback {
                Text(L10n.string("No key needed for a local server."))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            } else {
                SecureField(L10n.string("API key"), text: $apiKey)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
                    )
            }
        }
    }

    private var addButton: some View {
        Button(action: beginAdd) {
            Label(L10n.string("Add Model"), systemImage: "plus")
        }
        .buttonStyle(.capsule(.secondary, size: .regular))
        .controlSize(.large)
        .disabled(isAdding || editing != nil)
    }

    @ViewBuilder
    private var errorMessage: some View {
        if let error {
            Text(verbatim: error)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Status.errorColor)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var canSave: Bool {
        !baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !modelID.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func field(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Background.baseColor.opacity(AppTheme.Opacity.medium))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
            )
    }

    private func load() {
        models = CustomModelStore.load()
    }

    private func beginAdd() {
        editing = nil
        isAdding = true
        name = ""
        baseURL = ""
        modelID = ""
        apiKey = ""
        loadedKey = ""
        error = nil
    }

    private func beginEdit(_ model: CustomAgentModel) {
        editing = model
        isAdding = false
        name = model.name
        baseURL = model.baseURL.absoluteString
        modelID = model.modelID
        apiKey = ""
        loadedKey = ""
        error = nil
        let id = model.id
        Task { @MainActor in
            let stored = await CustomModelStore.loadKey(for: id)
            // Only fill a field the user has not already typed into: a late write would
            // otherwise replace a freshly typed key with the stored one.
            if apiKey.isEmpty {
                apiKey = stored
                loadedKey = stored
            }
        }
    }

    private func cancel() {
        editing = nil
        isAdding = false
        name = ""
        baseURL = ""
        modelID = ""
        apiKey = ""
        loadedKey = ""
        error = nil
    }

    private func save() {
        // Snapshot the form: the reset below clears these, and a detached write that read the
        // live state would store empty values — deleting the key it had just been given.
        let pendingName = name
        let pendingBaseURL = baseURL
        let pendingModelID = modelID
        let pendingID = editing?.id
        let pendingKey: CustomKeyUpdate = apiKey == loadedKey
            ? .unchanged
            : (apiKey.isEmpty ? .clear : .set(apiKey))
        error = nil
        cancel()
        load()
        Task { @MainActor in
            let result = await CustomModelStore.upsert(
                id: pendingID,
                name: pendingName,
                baseURL: pendingBaseURL,
                modelID: pendingModelID,
                key: pendingKey,
                defaults: .standard
            )
            if case .failed(let message) = result {
                error = message
                return
            }
            load()
            // Announced only after the credential is readable, so the agent does not cache an
            // empty key for a model that has one.
            NotificationCenter.default.post(name: .agentCustomEndpointChanged, object: nil)
        }
    }

    private func remove(_ model: CustomAgentModel) {
        CustomModelStore.remove(id: model.id)
        Task { await CustomModelStore.setKey(nil, for: model.id) }
        if editing?.id == model.id { cancel() }
        load()
        NotificationCenter.default.post(name: .agentCustomEndpointChanged, object: nil)
    }
}
