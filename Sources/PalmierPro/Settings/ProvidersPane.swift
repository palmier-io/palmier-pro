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

private enum AudioGenerationCredentialProvider: String, CaseIterable, Identifiable, Equatable {
    case elevenLabs
    case googleAI
    case minimax
    case sonilo
    case mirelo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .elevenLabs: "ElevenLabs"
        case .googleAI: "Google AI"
        case .minimax: "MiniMax"
        case .sonilo: "Sonilo"
        case .mirelo: "Mirelo"
        }
    }

    var subtitle: String {
        switch self {
        case .elevenLabs:
            "Speech and music model access. The key is stored in your macOS Keychain."
        case .googleAI:
            "Gemini and Lyria model access. The key is stored in your macOS Keychain."
        case .minimax:
            "Music model access. Choose the API region that issued the key."
        case .sonilo:
            "Video-to-music model access. The key is stored in your macOS Keychain."
        case .mirelo:
            "Video-to-sound-effect model access. The key is stored in your macOS Keychain."
        }
    }

    var placeholder: String {
        switch self {
        case .googleAI: "API key"
        default: "API key"
        }
    }

    var keychainAccount: String { "audio-generation-\(rawValue)-api-key" }

    var docsURL: URL? {
        switch self {
        case .elevenLabs: URL(string: "https://elevenlabs.io/docs/api-reference/models")
        case .googleAI: URL(string: "https://ai.google.dev/api/models")
        case .minimax: MiniMaxAPIRegion.stored.docsURL
        case .sonilo: URL(string: "https://platform.sonilo.com/")
        case .mirelo: URL(string: "https://mirelo.ai/api-docs")
        }
    }
}

private enum MiniMaxAPIRegion: String, CaseIterable, Identifiable {
    case mainlandChina
    case global

    private static let defaultsKey = "audioGenerationMiniMaxAPIRegion"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mainlandChina: "Mainland China"
        case .global: "Global"
        }
    }

    var modelsURL: URL {
        switch self {
        case .mainlandChina: URL(string: "https://api.minimaxi.com/v1/models")!
        case .global: URL(string: "https://api.minimax.io/v1/models")!
        }
    }

    var docsURL: URL {
        switch self {
        case .mainlandChina: URL(string: "https://platform.minimaxi.com/docs/api-reference/models/openai/list-models")!
        case .global: URL(string: "https://platform.minimax.io/docs/api-reference/models/openai/list-models")!
        }
    }

    static var stored: MiniMaxAPIRegion {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let region = MiniMaxAPIRegion(rawValue: raw)
        else { return .mainlandChina }
        return region
    }

    static func save(_ region: MiniMaxAPIRegion) {
        UserDefaults.standard.set(region.rawValue, forKey: defaultsKey)
    }
}

private enum AudioGenerationCredentialStore {
    static func save(_ key: String, provider: AudioGenerationCredentialProvider) {
        KeychainStore.save(key, account: provider.keychainAccount)
    }

    static func load(provider: AudioGenerationCredentialProvider) -> String? {
        KeychainStore.load(account: provider.keychainAccount)
    }

    static func delete(provider: AudioGenerationCredentialProvider) {
        KeychainStore.delete(account: provider.keychainAccount)
    }
}

private struct AudioProviderModelProbeResult: Sendable {
    let count: Int?
}

private enum AudioProviderModelProbeError: LocalizedError {
    case transport(String)
    case api(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .transport(let message): message
        case .api(_, let message): message
        }
    }
}

private enum AudioProviderModelProbe {
    static func fetch(
        provider: AudioGenerationCredentialProvider,
        apiKey: String,
        miniMaxRegion: MiniMaxAPIRegion = MiniMaxAPIRegion.stored
    ) async throws -> AudioProviderModelProbeResult {
        switch provider {
        case .elevenLabs:
            return try await fetchJSONCount(
                url: URL(string: "https://api.elevenlabs.io/v1/models")!,
                headers: ["xi-api-key": apiKey],
                arrayKey: nil
            )
        case .googleAI:
            var components = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            components.queryItems = [URLQueryItem(name: "key", value: apiKey)]
            return try await fetchJSONCount(url: components.url!, headers: [:], arrayKey: "models")
        case .minimax:
            return try await fetchJSONCount(
                url: miniMaxRegion.modelsURL,
                headers: ["Authorization": "Bearer \(apiKey)"],
                arrayKey: "data"
            )
        case .sonilo, .mirelo:
            return AudioProviderModelProbeResult(count: nil)
        }
    }

    private static func fetchJSONCount(url: URL, headers: [String: String], arrayKey: String?) async throws -> AudioProviderModelProbeResult {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "accept")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AudioProviderModelProbeError.transport("Non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw AudioProviderModelProbeError.api(status: http.statusCode, message: detail)
        }
        let object = try JSONSerialization.jsonObject(with: data)
        if let array = object as? [Any] {
            return AudioProviderModelProbeResult(count: array.count)
        }
        if let arrayKey,
           let dictionary = object as? [String: Any],
           let array = dictionary[arrayKey] as? [Any] {
            return AudioProviderModelProbeResult(count: array.count)
        }
        return AudioProviderModelProbeResult(count: nil)
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
