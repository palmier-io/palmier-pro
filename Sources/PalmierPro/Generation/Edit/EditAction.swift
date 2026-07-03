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
                return .disabled(reason: "Upscale only works on video or images")
            }
            if asset.type == .video {
                guard let h = asset.sourceHeight, h > 0 else {
                    return .disabled(reason: "Loading video metadata…")
                }
                if h >= 2160 {
                    return .disabled(reason: "Already 4K or higher")
                }
            }
            if Self.isUpscaleResult(asset) {
                return .disabled(reason: "Already upscaled")
            }
            if asset.isGenerating {
                return .disabled(reason: "Generation in progress")
            }
            return .available

        case .edit:
            switch asset.type {
            case .video:
                let duration = effectiveDurationOverride ?? Self.effectiveDuration(of: asset)
                guard duration > 0 else {
                    return .disabled(reason: "Loading video metadata…")
                }
                guard duration <= EditAction.editMaxDurationSeconds else {
                    return .disabled(reason: "Edit supports up to \(Int(EditAction.editMaxDurationSeconds))s (this is \(Int(duration.rounded()))s)")
                }
            case .image:
                break // images have no duration constraint
            case .audio:
                return .disabled(reason: "Edit doesn't support audio")
            case .text:
                return .disabled(reason: "Edit doesn't support text")
            case .lottie:
                return .disabled(reason: "Edit doesn't support Lottie")
            case .sequence:
                return .disabled(reason: "Edit doesn't support sequences")
            }
            if asset.isGenerating {
                return .disabled(reason: "Generation in progress")
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
                return .disabled(reason: "Create Video only works on images")
            }
            if asset.isGenerating {
                return .disabled(reason: "Generation in progress")
            }
            return .available

        case .rerun:
            guard asset.isGenerated else {
                return .disabled(reason: "Only available for AI-generated media")
            }
            if asset.isGenerating {
                return .disabled(reason: "Generation in progress")
            }
            guard let modelId = asset.generationInput?.model, ModelRegistry.exists(id: modelId) else {
                return .disabled(reason: "Model no longer available")
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
            return .disabled(reason: "\(kind.title) only works on video")
        }
        if asset.isGenerating {
            return .disabled(reason: "Generation in progress")
        }
        let duration = effectiveDurationOverride ?? effectiveDuration(of: asset)
        guard duration > 0 else {
            return .disabled(reason: "Loading video metadata…")
        }
        guard let model = kind.model else {
            return .disabled(reason: "\(kind.providerName) model not available")
        }
        if let err = model.validate(spanSeconds: duration) {
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
