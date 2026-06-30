import AppKit
import SwiftUI

struct ProvidersPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            OpenRouterProviderPane()
            Divider().overlay(AppTheme.Border.subtleColor)
            VolcengineSpeechPane()
        }
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
