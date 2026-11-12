import Foundation

struct RuntimeCapability: Sendable, Equatable {
    enum Status: String, Sendable {
        case available, unavailable, needsPreparation, unknown
    }

    enum BlockerKind: String, Sendable, Equatable {
        case buildExclusion = "build_exclusion"
        case missingModelDownload = "missing_model_download"
        case missingProviderCredential = "missing_provider_credential"
        case unsupportedModality = "unsupported_modality"
        case temporaryProviderFailure = "temporary_provider_failure"
    }

    enum Reason: String, Sendable {
        case hostedBuildExcluded = "hosted_build_excluded"
        case speechBuildExcluded = "bundled_speech_excluded"
        case runtimeUnavailable = "runtime_unavailable"
        case backendUnconfigured = "backend_unconfigured"
        case authenticationRequired = "authentication_required"
        case creditsRequired = "credits_required"
        case catalogUnavailable = "catalog_unavailable"
        case disabled
        case modelNotInstalled = "model_not_installed"
        case modelPreparing = "model_preparing"
        case modelFailed = "model_failed"
        case modelNotChecked = "model_not_checked"
        case credentialMissing = "credential_missing"
        case voiceUnavailable = "voice_unavailable"
        case unsupportedModality = "unsupported_modality"
        case clientDependent = "client_dependent"
        case onDemandModel = "on_demand_model"
        case temporaryProviderFailure = "temporary_provider_failure"

        var blockerKind: BlockerKind {
            switch self {
            case .hostedBuildExcluded, .speechBuildExcluded, .runtimeUnavailable:
                .buildExclusion
            case .modelNotInstalled, .modelPreparing, .modelNotChecked, .onDemandModel, .voiceUnavailable:
                .missingModelDownload
            case .backendUnconfigured, .authenticationRequired, .creditsRequired, .credentialMissing:
                .missingProviderCredential
            case .unsupportedModality, .clientDependent, .disabled:
                .unsupportedModality
            case .modelFailed, .temporaryProviderFailure, .catalogUnavailable:
                .temporaryProviderFailure
            }
        }

        var messageKey: String {
            switch self {
            case .hostedBuildExcluded: L10n.key("Hosted generation is unavailable in this build. Signing in or adding credits will not enable it.")
            case .speechBuildExcluded: L10n.key("Voice denoising requires a build with BundledSpeech enabled.")
            case .runtimeUnavailable: L10n.key("Voice denoising requires the bundled MLX runtime. Open the packaged app to use it.")
            case .backendUnconfigured: L10n.key("The hosted service is not configured.")
            case .authenticationRequired: L10n.key("Sign in to use hosted generation.")
            case .creditsRequired: L10n.key("Add credits to use hosted generation.")
            case .catalogUnavailable: L10n.key("The model catalog is not ready. Wait for it to load before generating.")
            case .disabled: L10n.key("Visual search is disabled in Settings.")
            case .modelNotInstalled: L10n.key("The visual search model must be downloaded before results are complete.")
            case .modelPreparing: L10n.key("The visual search model is downloading or preparing. Results are not complete yet.")
            case .modelFailed: L10n.key("The visual search model failed to prepare. Retry its setup in Settings.")
            case .modelNotChecked: L10n.key("The visual search model has not been checked yet. Search prepares it on demand.")
            case .credentialMissing: L10n.key("Stock video search requires a configured Pexels or Pixabay API key.")
            case .voiceUnavailable: L10n.key("No usable local speech engine and voice were found. Install a voice before generating speech.")
            case .unsupportedModality: L10n.key("The selected chat model is configured without image input.")
            case .clientDependent: L10n.key("Image input support is undeclared. The selected endpoint or MCP client must support images.")
            case .onDemandModel: L10n.key("The denoising model is prepared on demand and may require a download. Model readiness is checked during execution.")
            case .temporaryProviderFailure: L10n.key("The remote provider reported a temporary failure. Try again in a moment.")
            }
        }
    }

    let status: Status
    var reason: Reason?

    static let available = RuntimeCapability(status: .available)
    var canStart: Bool { status != .unavailable }
    @MainActor var localizedMessage: String { reason.map { L10n.string(key: $0.messageKey) } ?? "" }

    var receipt: [String: Any] {
        var value: [String: Any] = ["status": status.rawValue, "canStart": canStart]
        if let reason {
            value["reason"] = reason.rawValue
            value["blockerKind"] = reason.blockerKind.rawValue
            // Only the UI resolves this source message into a translation.
            value["message"] = reason.messageKey
        }
        return value
    }

    func requireAvailable() throws {
        guard canStart else { throw RuntimeCapabilityError(capability: self) }
    }
}

struct RuntimeCapabilityError: LocalizedError {
    let capability: RuntimeCapability
    var errorDescription: String? { capability.reason?.messageKey }
}

enum RuntimeCapabilities {
    #if BUNDLED_SPEECH
    static let bundledSpeech = true
    #else
    static let bundledSpeech = false
    #endif

    struct LocalInputs: Sendable {
        var pexelsConfigured = false
        var pixabayConfigured = false
        var systemSpeechLanguages: [String] = []
        var piperInstalled = false
        var piperLanguages: [String] = []

        @concurrent
        static func load() async throws -> LocalInputs {
            async let pexels = StockMediaCredentials.pexelsKey()
            async let pixabay = StockMediaCredentials.pixabayKey()
            try Task.checkCancellation()
            let systemLanguages = SpeechSynthesizer.installedLanguages()
            let piperInstalled = PiperTTS.isAvailable
            let piperLanguages = piperInstalled ? PiperTTS.installedLanguages : []
            let keys = await (pexels, pixabay)
            let result = LocalInputs(
                pexelsConfigured: !keys.0.isEmpty,
                pixabayConfigured: !keys.1.isEmpty,
                systemSpeechLanguages: systemLanguages,
                piperInstalled: piperInstalled,
                piperLanguages: piperLanguages
            )
            try Task.checkCancellation()
            return result
        }
    }

    static func hostedGeneration(
        enabled: Bool, configured: Bool, signedIn: Bool, hasCredits: Bool, catalogLoaded: Bool
    ) -> RuntimeCapability {
        if !enabled { return .init(status: .unavailable, reason: .hostedBuildExcluded) }
        if !configured { return .init(status: .unavailable, reason: .backendUnconfigured) }
        if !signedIn { return .init(status: .unavailable, reason: .authenticationRequired) }
        if !hasCredits { return .init(status: .unavailable, reason: .creditsRequired) }
        if !catalogLoaded { return .init(status: .unavailable, reason: .catalogUnavailable) }
        return .available
    }

    static func denoising(bundledSpeech: Bool, runtimeAvailable: Bool) -> RuntimeCapability {
        if !bundledSpeech { return .init(status: .unavailable, reason: .speechBuildExcluded) }
        if !runtimeAvailable { return .init(status: .unavailable, reason: .runtimeUnavailable) }
        return .init(status: .needsPreparation, reason: .onDemandModel)
    }

    static func imageInput(supported: Bool?) -> RuntimeCapability {
        switch supported {
        case true: .available
        case false: .init(status: .unavailable, reason: .unsupportedModality)
        case nil: .init(status: .unknown, reason: .clientDependent)
        }
    }

    static func visualInspection(imageInputSupported: Bool?) -> RuntimeCapability {
        imageInput(supported: imageInputSupported)
    }

    @MainActor
    static func visualSearch(_ model: any VisualSearchModelLoading) -> RuntimeCapability {
        guard model.enabled else { return .init(status: .unavailable, reason: .disabled) }
        switch model.state {
        case .ready: return .available
        case .unknown: return .init(status: .needsPreparation, reason: .modelNotChecked)
        case .notInstalled: return .init(status: .needsPreparation, reason: .modelNotInstalled)
        case .downloading, .preparing: return .init(status: .needsPreparation, reason: .modelPreparing)
        case .failed: return .init(status: .unavailable, reason: .modelFailed)
        }
    }

    static func stockVideo(_ inputs: LocalInputs) -> RuntimeCapability {
        inputs.pexelsConfigured || inputs.pixabayConfigured
            ? .available : .init(status: .unavailable, reason: .credentialMissing)
    }

    static func speech(_ inputs: LocalInputs) -> RuntimeCapability {
        !inputs.systemSpeechLanguages.isEmpty || (inputs.piperInstalled && !inputs.piperLanguages.isEmpty)
            ? .available : .init(status: .unavailable, reason: .voiceUnavailable)
    }

    @MainActor
    static func recommendations(
        local: LocalInputs, visualModel: any VisualSearchModelLoading,
        imageInputSupported: Bool?, hosted: RuntimeCapability, denoising: RuntimeCapability
    ) -> [String] {
        var items: [String] = []
        if !hosted.canStart {
            items.append("Hosted generation is excluded in this build; use local library footage, stock media, and local speech.")
        }
        if !denoising.canStart {
            if denoising.reason == .speechBuildExcluded {
                items.append("Voice denoising requires building with '--traits BundledSpeech'; use loudness matching and de-breathing for audio cleanup.")
            } else if denoising.reason == .runtimeUnavailable {
                items.append("MLX runtime is unavailable in this environment; run the packaged app on Apple Silicon to use local voice enhancement.")
            }
        }
        if !stockVideo(local).canStart {
            items.append("Stock video search is unconfigured; add a free Pexels or Pixabay API key in Settings, or use local footage.")
        }
        if !speech(local).canStart {
            items.append("No speech voice found; install a macOS system voice or install Piper TTS to generate narration.")
        }
        if let supported = imageInputSupported, !supported {
            items.append("The configured agent model does not support images; visual inspection of frames is unavailable.")
        }
        if !visualSearch(visualModel).canStart {
            items.append("Visual search model is not ready; search footage using spoken transcripts until the model finishes preparing.")
        }
        return items
    }

    @MainActor
    static func receipt(
        local: LocalInputs, visualModel: any VisualSearchModelLoading,
        imageInputSupported: Bool?, hosted: RuntimeCapability, cloudTranscription: RuntimeCapability,
        denoising: RuntimeCapability
    ) -> [String: Any] {
        let visualInspectionCap = visualInspection(imageInputSupported: imageInputSupported)
        let operations: [String: RuntimeCapability] = [
            "generate_video": hosted, "generate_image": hosted, "generate_audio": hosted,
            "cloud_transcription": cloudTranscription,
            "upscale_media": hosted, "enhance_media": localUpscaleCapability(bundledSpeech: RuntimeCapabilities.bundledSpeech, runtimeAvailable: MLXRuntime.isAvailable),
            "denoise_audio": denoising, "enhance_voice": denoising,
            "debreath_audio": .available, "match_loudness": .available,
            "generate_drone": .available, "generate_speech": speech(local),
            "inspect_media": .available, "inspect_timeline": visualInspectionCap,
            "visual_inspection": visualInspectionCap,
            "visual_search": visualSearch(visualModel),
            "stock_video_search": stockVideo(local),
            "stock_image_search": .available, "stock_audio_search": .available,
        ]
        return [
            "operations": operations.mapValues(\.receipt),
            "agentImageInput": imageInput(supported: imageInputSupported).receipt,
            "stockProviders": ["openverse": true, "pexels": local.pexelsConfigured, "pixabay": local.pixabayConfigured],
            "speechLanguages": ["system": local.systemSpeechLanguages, "piper": local.piperLanguages],
            "recommendations": recommendations(
                local: local, visualModel: visualModel, imageInputSupported: imageInputSupported,
                hosted: hosted, denoising: denoising
            ),
            "notes": [
                "Availability describes prerequisites, not a guarantee that a remote provider or media request will succeed.",
                "Specific models, voices, languages, references, and credit costs are validated again when executing.",
                "A chat API key does not enable hosted media generation. Keep required source type and language explicit; report unavailable coverage instead of silently substituting.",
            ],
        ]
    }

    /// Local upscale/media enhancement capability — available when BundledSpeech trait is
    /// enabled and MLX runtime is present. `enhance_media` works without signing in or
    /// adding credits; UI disables it gracefully when the trait is absent.
    static func localUpscaleCapability(bundledSpeech: Bool, runtimeAvailable: Bool) -> RuntimeCapability {
        if !bundledSpeech { return .init(status: .unavailable, reason: .speechBuildExcluded) }
        if !runtimeAvailable { return .init(status: .unavailable, reason: .runtimeUnavailable) }
        return .init(status: .available)
    }
}
