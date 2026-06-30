import AppKit
import SwiftUI

struct ProvidersPane: View {
    var body: some View {
        VideoGenerationPane()
    }
}

struct VideoGenerationPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            OpenRouterProviderPane()
            Divider().overlay(AppTheme.Border.subtleColor)
            ModelsPane(scope: .visual)
        }
    }
}

struct AudioGenerationPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            ForEach(AudioGenerationCredentialProvider.allCases) { provider in
                AudioGenerationProviderPane(provider: provider)
                if provider != AudioGenerationCredentialProvider.allCases.last {
                    Divider().overlay(AppTheme.Border.subtleColor)
                }
            }
            Divider().overlay(AppTheme.Border.subtleColor)
            ModelsPane(scope: .audio)
        }
    }
}

private struct AudioGenerationProviderPane: View {
    let provider: AudioGenerationCredentialProvider

    @State private var apiKeyDraft = ""
    @State private var miniMaxRegion = MiniMaxAPIRegion.stored
    @State private var hasKey = false
    @State private var maskedKey = ""
    @State private var isLoading = false
    @State private var statusText = ""
    @State private var errorText: String?
    @FocusState private var keyFocused: Bool

    private var trimmedAPIKeyDraft: String {
        apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header

            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(hasKey ? maskedKey : provider.placeholder, text: $apiKeyDraft)
                    .textFieldStyle(.plain)
                    .focused($keyFocused)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .onSubmit(saveKey)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(inputBackground)
                    .overlay(inputBorder)
                    .animation(.easeOut(duration: AppTheme.Anim.hover), value: keyFocused)

                trailingControls
            }

            if provider == .minimax {
                miniMaxRegionPicker
            }

            statusRow

            if let errorText {
                Text(errorText)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refreshKeyState)
    }

    private var miniMaxRegionPicker: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Text("API Region")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            Picker("", selection: $miniMaxRegion) {
                ForEach(MiniMaxAPIRegion.allCases) { region in
                    Text(region.title).tag(region)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .onChange(of: miniMaxRegion) { _, newValue in
                MiniMaxAPIRegion.save(newValue)
                if hasKey {
                    Task { await refreshModels() }
                }
            }

            Text(miniMaxRegion.modelsURL.host ?? "")
                .font(.system(size: AppTheme.FontSize.xs, design: .monospaced))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(provider.title)
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text(provider.subtitle)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                if let docsURL = provider.docsURL {
                    Button(action: { NSWorkspace.shared.open(docsURL, configuration: .init(), completionHandler: nil) }) {
                        HStack(spacing: AppTheme.Spacing.xxs) {
                            Text("API docs")
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
    }

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if !trimmedAPIKeyDraft.isEmpty {
                Button(action: saveKey) {
                    Label("Save", systemImage: "checkmark")
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
            }

            if hasKey && trimmedAPIKeyDraft.isEmpty {
                Button(action: removeKey) {
                    Image(systemName: "trash")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.large)
                .help("Remove API key")
            }

            Button {
                Task { await refreshModels() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .disabled(isLoading || !hasKey)
            .help("Refresh models")
        }
    }

    private var statusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Circle()
                .fill(hasKey ? AppTheme.Status.successColor : AppTheme.Text.mutedColor)
                .frame(width: AppTheme.Spacing.smMd, height: AppTheme.Spacing.smMd)

            Text(hasKey ? "API key saved" : "API key required")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            Spacer(minLength: AppTheme.Spacing.md)

            Text(modelStatus)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
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

    private var modelStatus: String {
        if isLoading { return "Loading models" }
        if !statusText.isEmpty { return statusText }
        if hasKey { return "Models not loaded" }
        return "Not configured"
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .fill(Color.black.opacity(keyFocused ? AppTheme.Opacity.moderate : AppTheme.Opacity.muted))
    }

    private var inputBorder: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(
                keyFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                lineWidth: AppTheme.BorderWidth.thin
            )
    }

    private func saveKey() {
        let key = trimmedAPIKeyDraft
        guard !key.isEmpty else { return }
        AudioGenerationCredentialStore.save(key, provider: provider)
        apiKeyDraft = ""
        keyFocused = false
        applyKey(key)
        Task { await refreshModels() }
    }

    private func removeKey() {
        AudioGenerationCredentialStore.delete(provider: provider)
        apiKeyDraft = ""
        hasKey = false
        maskedKey = ""
        statusText = ""
        errorText = nil
    }

    private func refreshKeyState() {
        miniMaxRegion = MiniMaxAPIRegion.stored
        let key = AudioGenerationCredentialStore.load(provider: provider) ?? ""
        applyKey(key)
    }

    private func applyKey(_ key: String) {
        hasKey = !key.isEmpty
        maskedKey = mask(key)
    }

    private func refreshModels() async {
        guard let key = AudioGenerationCredentialStore.load(provider: provider) else { return }
        isLoading = true
        errorText = nil
        defer { isLoading = false }
        do {
            let result = try await AudioProviderModelProbe.fetch(provider: provider, apiKey: key, miniMaxRegion: miniMaxRegion)
            if let count = result.count {
                statusText = "\(count) models"
            } else {
                statusText = "Model endpoint not exposed"
            }
        } catch {
            statusText = "Models not loaded"
            errorText = error.localizedDescription
        }
    }

    private func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "\u{2022}", count: 32) }
        return String(repeating: "\u{2022}", count: 36) + key.suffix(4)
    }
}

private struct OpenRouterProviderPane: View {
    @Bindable private var openRouter = OpenRouterService.shared
    @State private var apiKeyDraft = ""
    @FocusState private var keyFocused: Bool

    private let keysURL = URL(string: "https://openrouter.ai/settings/keys")!
    private var trimmedAPIKeyDraft: String {
        apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            header

            HStack(spacing: AppTheme.Spacing.sm) {
                SecureField(openRouter.hasAPIKey ? "Replace API key" : "OpenRouter API key", text: $apiKeyDraft)
                    .textFieldStyle(.plain)
                    .focused($keyFocused)
                    .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .onSubmit(saveKey)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.smMd)
                    .background(inputBackground)
                    .overlay(inputBorder)
                    .animation(.easeOut(duration: AppTheme.Anim.hover), value: keyFocused)

                trailingControls
            }

            statusRow

            if let error = openRouter.lastError {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("OpenRouter")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Use OpenRouter for image and video generation. The key is stored in your macOS Keychain.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: openKeys) {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        Text("API keys")
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

    @ViewBuilder
    private var trailingControls: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            if !trimmedAPIKeyDraft.isEmpty {
                Button(action: saveKey) {
                    Label("Save", systemImage: "checkmark")
                }
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
            }

            if openRouter.hasAPIKey && trimmedAPIKeyDraft.isEmpty {
                Button(action: removeKey) {
                    Image(systemName: "trash")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                }
                .buttonStyle(.capsule(.secondary, size: .regular))
                .controlSize(.large)
                .help("Remove API key")
            }

            Button {
                Task { await openRouter.refreshModels() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
            }
            .buttonStyle(.capsule(.secondary, size: .regular))
            .controlSize(.large)
            .disabled(openRouter.isLoading)
            .help("Refresh models")
        }
    }

    private var statusRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Circle()
                .fill(openRouter.hasAPIKey ? AppTheme.Status.successColor : AppTheme.Text.mutedColor)
                .frame(width: AppTheme.Spacing.smMd, height: AppTheme.Spacing.smMd)

            Text(openRouter.hasAPIKey ? "API key saved" : "API key required for generation")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            Spacer(minLength: AppTheme.Spacing.md)

            Text(modelStatus)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
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

    private var modelStatus: String {
        if openRouter.isLoading { return "Loading models" }
        if openRouter.isLoaded {
            return "\(openRouter.image.count + openRouter.video.count) models"
        }
        return "Models not loaded"
    }

    private var inputBackground: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .fill(Color.black.opacity(keyFocused ? AppTheme.Opacity.moderate : AppTheme.Opacity.muted))
    }

    private var inputBorder: some View {
        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(
                keyFocused ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor,
                lineWidth: AppTheme.BorderWidth.thin
            )
    }

    private func saveKey() {
        let key = trimmedAPIKeyDraft
        guard !key.isEmpty else { return }
        openRouter.saveAPIKey(key)
        apiKeyDraft = ""
        keyFocused = false
    }

    private func removeKey() {
        openRouter.removeAPIKey()
        apiKeyDraft = ""
    }

    private func openKeys() {
        NSWorkspace.shared.open(keysURL, configuration: .init(), completionHandler: nil)
    }
}
