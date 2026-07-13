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
            ("Voice Cleanup", "Remove background sound and keep speech", "Clean Up Voice…", "waveform", "Add Cleaned Voice")
        case .dubbing:
            ("Dubbing", "Translate speech into another language", "Dub…", "globe", "Add Dubbed Voice")
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
            return .disabled(reason: "\(title) requires audio or video")
        }
        if asset.type == .video && !asset.hasAudio {
            return .disabled(reason: "Video has no audio track")
        }
        if asset.isGenerating {
            return .disabled(reason: "Generation in progress")
        }
        guard let model else {
            return .disabled(reason: "\(title) model not available")
        }
        guard model.acceptsSource(asset.type) else {
            return .disabled(reason: "\(model.displayName) does not accept this media")
        }
        let duration = effectiveDurationOverride ?? asset.duration
        guard duration > 0 else {
            return .disabled(reason: "Loading media metadata…")
        }
        if let error = model.validate(spanSeconds: duration) {
            return .disabled(reason: error)
        }
        return .available
    }
}
