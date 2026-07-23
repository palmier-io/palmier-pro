import Foundation

enum AudioTransformEditKind: CaseIterable, Equatable {
    case cleanup
    case dubbing

    private typealias Copy = (
        title: String,
        description: String,
        menu: String,
        icon: String,
        timelineAction: String
    )

    private var copy: Copy {
        switch self {
        case .cleanup:
            (
                L10n.string("Voice Cleanup"),
                L10n.string("Remove background sound and keep speech"),
                L10n.string("Clean Up Voice…"),
                "waveform",
                L10n.string("Add Cleaned Voice")
            )
        case .dubbing:
            (
                L10n.string("Dubbing"),
                L10n.string("Translate speech into another language"),
                L10n.string("Dub…"),
                "globe",
                L10n.string("Add Dubbed Voice")
            )
        }
    }

    var category: AudioModelConfig.Category {
        switch self {
        case .cleanup: .cleanup
        case .dubbing: .dubbing
        }
    }

    var title: String { copy.title }
    var description: String { copy.description }
    var menuTitle: String { copy.menu }
    var iconName: String { copy.icon }
    var timelineActionName: String { copy.timelineAction }

    @MainActor
    var model: AudioModelConfig? {
        AudioModelConfig.allModels.first { $0.category == category }
    }

    @MainActor
    static func available(
        for asset: MediaAsset,
        effectiveDurationOverride: Double? = nil
    ) -> [Self] {
        allCases.filter {
            $0.availability(
                for: asset,
                effectiveDurationOverride: effectiveDurationOverride
            ).isAvailable
        }
    }

    @MainActor
    func availability(
        for asset: MediaAsset,
        effectiveDurationOverride: Double? = nil
    ) -> EditActionAvailability {
        guard asset.type == .audio || asset.type == .video else {
            return .disabled(reason: L10n.format("%@ requires audio or video", title))
        }
        if asset.type == .video && !asset.hasAudio {
            return .disabled(reason: L10n.string("Video has no audio track"))
        }
        if asset.isGenerating {
            return .disabled(reason: L10n.string("Generation in progress"))
        }
        guard let model else {
            return .disabled(reason: L10n.format("%@ model not available", title))
        }
        guard model.acceptsSource(asset.type) else {
            return .disabled(reason: L10n.format("%@ does not accept this media", model.displayName))
        }
        let duration = effectiveDurationOverride ?? asset.duration
        guard duration > 0 else {
            return .disabled(reason: L10n.string("Loading media metadata…"))
        }
        if let error = model.validate(spanSeconds: duration, localized: true) {
            return .disabled(reason: error)
        }
        return .available
    }
}
