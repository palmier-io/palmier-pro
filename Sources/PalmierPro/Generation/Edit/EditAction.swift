import Foundation

enum EditAction {
    case upscale
    case edit
    case rerun
    case lipSync
    case reframe
    case generateMusic
    case generateSFX
    case createVideo

    static let editMaxDurationSeconds: Double = 10.0

    var requiresPaidPlan: Bool {
        switch self {
        case .upscale, .edit, .lipSync, .reframe: true
        case .generateMusic, .generateSFX, .rerun, .createVideo: false
        }
    }

    func group(for mediaType: ClipType) -> AIEditActionGroup {
        switch self {
        case .generateMusic, .generateSFX:
            .audio
        case .rerun where mediaType == .audio:
            .audio
        case .upscale, .edit, .rerun, .lipSync, .reframe, .createVideo:
            .enhance
        }
    }

    @MainActor
    static func available(for asset: MediaAsset, effectiveDurationOverride: Double? = nil) -> [EditAction] {
        let candidates: [EditAction]
        switch asset.type {
        case .image: candidates = [.upscale, .edit, .rerun, .createVideo]
        case .video: candidates = [.upscale, .edit, .rerun, .lipSync, .reframe, .generateMusic, .generateSFX]
        case .audio, .text: candidates = [.upscale, .edit, .rerun]
        case .lottie, .sequence: candidates = []
        }
        return candidates.filter {
            $0.availability(for: asset, effectiveDurationOverride: effectiveDurationOverride).isAvailable
        }
    }

    @MainActor
    func availability(for asset: MediaAsset, effectiveDurationOverride: Double? = nil) -> EditActionAvailability {
        switch self {
        case .upscale:
            guard asset.type == .video || asset.type == .image else {
                return .disabled(reason: L10n.string("Upscale only works on video or images"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            return .available

        case .reframe:
            guard asset.type == .video else {
                return .disabled(reason: L10n.string("Reframe only works on video"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            guard let model = VideoModelConfig.reframe else {
                return .disabled(reason: L10n.string("Reframe model not available"))
            }
            let duration = effectiveDurationOverride ?? asset.resolvedDuration
            if let error = model.validateSourceDuration(duration) {
                return .disabled(reason: error)
            }
            return .available

        case .lipSync:
            guard asset.type == .video else {
                return .disabled(reason: L10n.string("Lip Sync only works on video"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            guard let model = VideoModelConfig.lipSync else {
                return .disabled(reason: L10n.string("Lip Sync model not available"))
            }
            let duration = effectiveDurationOverride ?? asset.resolvedDuration
            if let error = model.validateSourceDuration(duration) {
                return .disabled(reason: error)
            }
            return .available

        case .edit:
            switch asset.type {
            case .video:
                guard VideoModelConfig.edit != nil else {
                    return .disabled(reason: L10n.string("Edit model not available"))
                }
                let duration = effectiveDurationOverride ?? asset.resolvedDuration
                guard duration > 0 else {
                    return .disabled(reason: L10n.string("Loading video metadata…"))
                }
                guard duration <= EditAction.editMaxDurationSeconds else {
                    return .disabled(reason: L10n.string(
                        "Edit supports up to \(Int(EditAction.editMaxDurationSeconds))s (this is \(Int(duration.rounded()))s)"
                    ))
                }
            case .image:
                break // images have no duration constraint
            case .audio:
                return .disabled(reason: L10n.string("Edit doesn't support audio"))
            case .text:
                return .disabled(reason: L10n.string("Edit doesn't support text"))
            case .lottie:
                return .disabled(reason: L10n.string("Edit doesn't support Lottie"))
            case .sequence:
                return .disabled(reason: L10n.string("Edit doesn't support sequences"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            return .available

        case .generateMusic:
            return Self.videoAudioAvailability(
                for: asset,
                kind: .music,
                effectiveDurationOverride: effectiveDurationOverride
            )

        case .generateSFX:
            return Self.videoAudioAvailability(
                for: asset,
                kind: .sfx,
                effectiveDurationOverride: effectiveDurationOverride
            )

        case .createVideo:
            guard asset.type == .image else {
                return .disabled(reason: L10n.string("Create Video only works on images"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            return .available

        case .rerun:
            guard asset.isGenerated else {
                return .disabled(reason: L10n.string("Only available for AI-generated media"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            guard let modelId = asset.generationInput?.model, ModelRegistry.exists(id: modelId) else {
                return .disabled(reason: L10n.string("Model no longer available"))
            }
            return .available
        }
    }

    @MainActor
    private static func videoAudioAvailability(
        for asset: MediaAsset,
        kind: VideoToAudioEditKind,
        effectiveDurationOverride: Double?
    ) -> EditActionAvailability {
        guard asset.type == .video else {
            let reason = switch kind {
            case .music: L10n.string("Generate Music only works on video")
            case .sfx: L10n.string("Generate SFX only works on video")
            }
            return .disabled(reason: reason)
        }
        if asset.isGenerating {
            return .disabled(reason: L10n.string("Generation in progress"))
        }
        let duration = effectiveDurationOverride ?? asset.resolvedDuration
        guard duration > 0 else {
            return .disabled(reason: L10n.string("Loading video metadata…"))
        }
        guard let model = kind.model else {
            return .disabled(reason: L10n.string("\(kind.providerName) model not available"))
        }
        if let err = model.validate(spanSeconds: duration) {
            return .disabled(reason: err)
        }
        return .available
    }
}

enum AIEditActionGroup {
    case enhance
    case audio
}

enum EditActionAvailability: Equatable {
    case available
    case disabled(reason: String)

    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    var reason: String? {
        if case .disabled(let r) = self { return r }
        return nil
    }
}
