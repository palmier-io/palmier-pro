import SwiftUI

// Model catalog selection and per-model capability state.
extension GenerationView {

    var videoModels: [VideoModelConfig] { ModelCatalog.shared.video }
    var imageModels: [ImageModelConfig] { ModelCatalog.shared.image }
    var audioModels: [AudioModelConfig] { ModelCatalog.shared.audio }
    var upscaleModels: [UpscaleModelConfig] { ModelCatalog.shared.upscale }

    var videoModel: VideoModelConfig { selectedModel(videoModels, at: selectedVideoModelIndex) }
    var imageModel: ImageModelConfig { selectedModel(imageModels, at: selectedImageModelIndex) }
    var audioModel: AudioModelConfig { selectedModel(audioModels, at: selectedAudioModelIndex) }
    var upscaleModel: UpscaleModelConfig { selectedModel(upscaleModels, at: selectedUpscaleModelIndex) }

    var catalogReady: Bool {
        !videoModels.isEmpty
            && !imageModels.isEmpty
            && !audioModels.isEmpty
            && (selectedType != .upscale || !upscaleModels.isEmpty)
    }

    var availableGenerationTypes: [GenerationType] {
        upscaleModels.isEmpty ? GenerationType.allCases.filter { $0 != .upscale } : GenerationType.allCases
    }

    var aiAllowed: Bool { account.aiAllowed }

    var currentModelLocked: Bool {
        guard !account.isPaid else { return false }
        switch selectedType {
        case .video: return videoModel.paidOnly
        case .image: return imageModel.paidOnly
        case .audio: return audioModel.paidOnly
        case .upscale: return upscaleModel.paidOnly
        }
    }

    private func selectedModel<T>(_ models: [T], at index: Int) -> T {
        let safeIndex = models.indices.contains(index) ? index : models.startIndex
        return models[safeIndex]
    }

    private func isAvailable(_ paidOnly: Bool) -> Bool { account.isPaid || !paidOnly }

    var enabledVideoModels: [(index: Int, model: VideoModelConfig)] {
        videoModels.enumerated()
            .filter { ModelPreferences.shared.isEnabled($0.element.id) && isAvailable($0.element.paidOnly) }
            .map { (index: $0.offset, model: $0.element) }
    }
    var enabledImageModels: [(index: Int, model: ImageModelConfig)] {
        imageModels.enumerated()
            .filter { ModelPreferences.shared.isEnabled($0.element.id) && isAvailable($0.element.paidOnly) }
            .map { (index: $0.offset, model: $0.element) }
    }
    var enabledAudioModels: [(index: Int, model: AudioModelConfig)] {
        audioModels.enumerated()
            .filter { ModelPreferences.shared.isEnabled($0.element.id) && isAvailable($0.element.paidOnly) }
            .map { (index: $0.offset, model: $0.element) }
    }
    var enabledUpscaleModels: [(index: Int, model: UpscaleModelConfig)] {
        upscaleModels.enumerated()
            .filter { item in
                let supportsSource = upscaleSource.map { item.element.supports(source: $0) } ?? true
                return ModelPreferences.shared.isEnabled(item.element.id)
                    && isAvailable(item.element.paidOnly)
                    && supportsSource
            }
            .map { (index: $0.offset, model: $0.element) }
    }
    var enabledUpscaleModelsByType: [ClipType: [(index: Int, model: UpscaleModelConfig)]] {
        Dictionary(uniqueKeysWithValues: [ClipType.image, .video].map { type in
            (type, enabledUpscaleModels.filter { $0.model.supportedTypes.contains(type) })
        })
    }
    var enabledAudioModelsByCategory: [AudioModelConfig.Category: [(index: Int, model: AudioModelConfig)]] {
        var grouped: [AudioModelConfig.Category: [(index: Int, model: AudioModelConfig)]] = [:]
        grouped.reserveCapacity(AudioModelConfig.Category.allCases.count)
        for item in enabledAudioModels {
            grouped[item.model.category, default: []].append(item)
        }
        return grouped
    }

    func normalizeModelSelection() {
        switch selectedType {
        case .video:
            if !enabledVideoModels.contains(where: { $0.index == selectedVideoModelIndex }) {
                selectedVideoModelIndex = enabledVideoModels.first?.index ?? 0
            }
        case .image:
            if !enabledImageModels.contains(where: { $0.index == selectedImageModelIndex }) {
                selectedImageModelIndex = enabledImageModels.first?.index ?? 0
            }
        case .audio:
            if !enabledAudioModels.contains(where: { $0.index == selectedAudioModelIndex }) {
                selectedAudioModelIndex = enabledAudioModels.first?.index ?? 0
            }
        case .upscale:
            if !enabledUpscaleModels.contains(where: { $0.index == selectedUpscaleModelIndex }) {
                selectedUpscaleModelIndex = enabledUpscaleModels.first?.index ?? 0
            }
        }
    }

    var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespaces) }
    var isPromptEmpty: Bool { trimmedPrompt.isEmpty }
    var audioUsesSource: Bool {
        audioModel.acceptsSourceMedia
            && (!audioModel.inputs.contains(.text) || audioSource != nil)
    }
    var activeAudioInput: AudioModelConfig.Input {
        guard audioUsesSource, let audioSource else { return .text }
        return audioSource.type == .video ? .video : .audio
    }
    var showsPrompt: Bool {
        selectedType != .upscale && (selectedType != .audio || audioModel.inputs.contains(.text))
    }

    var initialAudioTargetLanguage: String {
        guard let languages = audioModel.targetLanguages else { return "" }
        if let preferred = audioModel.defaultTargetLanguage,
           languages.contains(preferred) {
            return preferred
        }
        return languages.first ?? ""
    }

    var hasAnySettings: Bool {
        switch selectedType {
        case .video: return !videoModel.durations.isEmpty || !videoModel.aspectRatios.isEmpty || videoModel.resolutions != nil || videoModel.audioDiscountRate != nil
        case .image: return !imageModel.aspectRatios.isEmpty || imageModel.resolutions != nil || imageModel.qualities != nil || imageModel.maxImages > 1
        case .audio:
            return audioModel.supportsInstrumental
                || (!audioUsesSource && audioModel.hasDurationControl)
        case .upscale:
            return true
        }
    }

    var currentModelName: String {
        switch selectedType {
        case .video: videoModel.displayName
        case .image: imageModel.displayName
        case .audio: audioModel.displayName
        case .upscale: upscaleModel.displayName
        }
    }

    var currentModelId: String {
        switch selectedType {
        case .video: videoModel.id
        case .image: imageModel.id
        case .audio: audioModel.id
        case .upscale: upscaleModel.id
        }
    }

    var currentAspectRatios: [String] {
        switch selectedType {
        case .video: videoModel.aspectRatios
        case .image: imageModel.aspectRatios
        case .audio: []
        case .upscale: []
        }
    }

    var currentResolutions: [String]? {
        switch selectedType {
        case .video: videoModel.resolutions
        case .image: imageModel.resolutions
        case .audio: nil
        case .upscale: nil
        }
    }

    var effectiveResolution: String? {
        currentResolutions != nil ? selectedResolution : nil
    }

    var currentQualities: [String]? {
        selectedType == .image ? imageModel.qualities : nil
    }

    private var audioPromptHint: String {
        audioModel.minPromptLength > 1 ? " (min \(audioModel.minPromptLength) chars)" : ""
    }

    var supportsAudioToggle: Bool {
        selectedType == .video && videoModel.audioDiscountRate != nil
    }

    var effectiveGenerateAudio: Bool {
        supportsAudioToggle ? generateAudio : true
    }

    var promptPlaceholder: String {
        switch selectedType {
        case .image: "Describe the image"
        case .video: "Describe the video"
        case .audio:
            switch audioModel.category {
            case .tts: "Text to speak\(audioPromptHint)"
            case .music: "Describe the music style or mood\(audioPromptHint)"
            case .sfx: "Describe the sound\(audioPromptHint)"
            case .cleanup, .dubbing: "No prompt needed"
            }
        case .upscale: "No prompt needed"
        }
    }

    var effectiveVideoSeconds: Int {
        guard videoModel.requiresSourceVideo else { return selectedDuration }
        if let trim = editor.pendingEditTrimmedSource,
           let sv = sourceVideo,
           trim.sourceURL == sv.url, trim.hasTrim {
            return max(1, Int(trim.durationSeconds.rounded()))
        }
        return max(0, Int((sourceVideo?.duration ?? 0).rounded()))
    }

    var effectiveAudioSourceSpanSeconds: Double {
        guard let source = audioSource else { return 0 }
        if let trim = audioSourceTrimmedSource(for: source), trim.hasTrim {
            return trim.durationSeconds
        }
        return source.duration
    }

    var effectiveAudioSourceSeconds: Int {
        max(1, Int(effectiveAudioSourceSpanSeconds.rounded()))
    }

    func audioSourceTrimmedSource(for source: MediaAsset) -> TrimmedSource? {
        guard let trim = editor.pendingEditTrimmedSource, trim.sourceURL == source.url else { return nil }
        return trim
    }

    var effectiveUpscaleSeconds: Int {
        guard let source = upscaleSource else { return 0 }
        if let trim = editor.pendingEditTrimmedSource,
           trim.sourceURL == source.url, trim.hasTrim {
            return max(1, Int(trim.durationSeconds.rounded()))
        }
        return source.type == .image ? 1 : max(1, Int(source.duration.rounded()))
    }

}
