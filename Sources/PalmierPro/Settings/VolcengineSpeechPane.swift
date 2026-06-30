import AppKit
import SwiftUI

struct VolcengineSpeechPane: View {
    @State private var hasKey = false
    @State private var maskedKey = ""
    @State private var keyDraft = ""
    @FocusState private var keyFocused: Bool

    private let consoleURL = URL(string: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey")!

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                header
                HStack(spacing: AppTheme.Spacing.sm) {
                    SecureField(hasKey ? maskedKey : "Volcengine API key", text: $keyDraft)
                        .textFieldStyle(.plain)
                        .focused($keyFocused)
                        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .onSubmit(saveKey)
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.smMd)
                        .background(inputBackground)
                        .overlay(inputBorder)

                    trailingControls
                }
            }
            Divider().overlay(AppTheme.Border.subtleColor)
        }
        .onAppear(perform: refresh)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Volcengine Speech")
                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Text("Use Seed ASR for captions and caption alignment. The key is stored in your macOS Keychain.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: openConsole) {
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
        let trimmed = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            Button("Save", action: saveKey)
                .buttonStyle(.capsule(.prominent, size: .regular))
                .controlSize(.large)
        } else if hasKey {
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
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        keyDraft = ""
        keyFocused = false
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                VolcengineSpeechKeychain.save(key)
            }.value
            applyKey(key)
        }
    }

    private func removeKey() {
        keyDraft = ""
        Task { @MainActor in
            await Task.detached(priority: .userInitiated) {
                VolcengineSpeechKeychain.delete()
            }.value
            applyKey("")
        }
    }

    private func refresh() {
        Task { @MainActor in
            let key = await Task.detached(priority: .utility) {
                VolcengineSpeechKeychain.load() ?? ""
            }.value
            applyKey(key)
        }
    }

    private func applyKey(_ key: String) {
        hasKey = !key.isEmpty
        maskedKey = mask(key)
    }

    private func mask(_ key: String) -> String {
        guard key.count > 4 else { return String(repeating: "\u{2022}", count: 32) }
        return String(repeating: "\u{2022}", count: 36) + key.suffix(4)
    }

    private func openConsole() {
        NSWorkspace.shared.open(consoleURL, configuration: .init(), completionHandler: nil)
    }
}
