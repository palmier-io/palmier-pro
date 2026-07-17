import Foundation

enum EditAction {
    case upscale
    case edit
    case generateMusic
    case generateSFX
    case rerun
    case createVideo

    static let editMaxDurationSeconds: Double = 10.0

    @MainActor
    static func available(for asset: MediaAsset, effectiveDurationOverride: Double? = nil) -> [EditAction] {
        let candidates: [EditAction]
        switch asset.type {
        case .image: candidates = [.upscale, .edit, .rerun, .createVideo]
        case .video: candidates = [.upscale, .edit, .generateMusic, .generateSFX, .rerun]
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
            if asset.type == .video {
                guard let h = asset.sourceHeight, h > 0 else {
                    return .disabled(reason: L10n.string("Loading video metadata…"))
                }
                if h >= 2160 {
                    return .disabled(reason: L10n.string("Already 4K or higher"))
                }
            }
            if Self.isUpscaleResult(asset) {
                return .disabled(reason: L10n.string("Already upscaled"))
            }
            if asset.isGenerating {
                return .disabled(reason: L10n.string("Generation in progress"))
            }
            return .available

        case .edit:
            switch asset.type {
            case .video:
                let duration = effectiveDurationOverride ?? Self.effectiveDuration(of: asset)
                guard duration > 0 else {
                    return .disabled(reason: L10n.string("Loading video metadata…"))
                }
                guard duration <= EditAction.editMaxDurationSeconds else {
                    return .disabled(reason: L10n.format(
                        "Edit supports up to %ds (this is %ds)",
                        Int(EditAction.editMaxDurationSeconds),
                        Int(duration.rounded())
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
    private static func isUpscaleResult(_ asset: MediaAsset) -> Bool {
        guard let modelId = asset.generationInput?.model else { return false }
        return UpscaleModelConfig.allIds.contains(modelId)
    }

    /// Falls back to the recorded generation duration when AVAsset metadata hasn't loaded.
    @MainActor
    private static func effectiveDuration(of asset: MediaAsset) -> Double {
        if asset.duration > 0 { return asset.duration }
        if let gd = asset.generationInput?.duration, gd > 0 { return Double(gd) }
        return 0
    }

    @MainActor
    private static func videoAudioAvailability(
        for asset: MediaAsset,
        kind: VideoToAudioEditKind,
        effectiveDurationOverride: Double?
    ) -> EditActionAvailability {
        guard asset.type == .video else {
            return .disabled(reason: L10n.format("%@ only works on video", kind.title))
        }
        if asset.isGenerating {
            return .disabled(reason: L10n.string("Generation in progress"))
        }
        let duration = effectiveDurationOverride ?? effectiveDuration(of: asset)
        guard duration > 0 else {
            return .disabled(reason: L10n.string("Loading video metadata…"))
        }
        guard let model = kind.model else {
            return .disabled(reason: L10n.format("%@ model not available", kind.providerName))
        }
        if let err = model.validate(spanSeconds: duration, localized: true) {
            return .disabled(reason: err)
        }
        return .available
    }
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
