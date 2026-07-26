import Foundation

struct AudioGenerationSubmission {
    let genInput: GenerationInput
    let model: AudioModelConfig
    let params: AudioGenerationParams
    let placeholderDuration: Double
    let name: String?
    let folderId: String?
    let references: [MediaAsset]
    let trimmedSourceOverride: TrimmedSource?

    @MainActor
    @discardableResult
    func submit(
        service: GenerationService,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        let usesReferences = model.supportsReferences
        let shouldExtractAudio = !usesReferences && !references.isEmpty && model.usesSourceURL
            && (references.first?.type == .video || trimmedSourceOverride?.hasTrim == true)
        let extractionTrim = shouldExtractAudio ? trimmedSourceOverride : nil
        let preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)?
        if shouldExtractAudio {
            preprocessRef = { index, asset in
                guard index == 0 else { return nil }
                return try await AudioTrackExtractor.extract(
                    sourceURL: asset.url,
                    trimmedSource: extractionTrim
                )
            }
        } else {
            preprocessRef = nil
        }
        let imageCount = genInput.referenceImageAssetIds?.count ?? 0
        let usesSourceURL = model.usesSourceURL
        let splitReferences: @Sendable ([String]) -> (image: String?, audio: [String]) = { uploaded in
            (imageCount > 0 ? uploaded.first : nil, Array(uploaded.dropFirst(imageCount)))
        }
        let buildParams: ([String]) -> BackendGenerationParams = { [params] uploaded in
            var resolvedParams = params
            if usesReferences {
                let referenceURLs = splitReferences(uploaded)
                resolvedParams.referenceImageURL = referenceURLs.image
                resolvedParams.referenceAudioURLs = referenceURLs.audio.isEmpty
                    ? nil : referenceURLs.audio
            } else if !uploaded.isEmpty {
                if usesSourceURL && resolvedParams.sourceURL == nil {
                    resolvedParams.sourceURL = uploaded.first
                } else if resolvedParams.videoURL == nil {
                    resolvedParams.videoURL = uploaded.first
                }
            }
            return .audio(resolvedParams)
        }
        let snapshotRefs: (@Sendable (inout GenerationInput, [String]) -> Void)?
        if usesReferences {
            snapshotRefs = { input, uploaded in
                let referenceURLs = splitReferences(uploaded)
                input.referenceImageURLs = referenceURLs.image.map { [$0] }
                input.referenceAudioURLs = referenceURLs.audio.isEmpty ? nil : referenceURLs.audio
            }
        } else {
            snapshotRefs = nil
        }
        return service.generate(
            genInput: genInput,
            assetType: .audio,
            placeholderDuration: placeholderDuration,
            references: references,
            trimmedSourceOverride: shouldExtractAudio ? nil : trimmedSourceOverride,
            name: name,
            folderId: folderId,
            buildParams: buildParams,
            snapshotRefs: snapshotRefs,
            preprocessRef: preprocessRef,
            fileExtension: "mp3",
            projectURL: projectURL,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    static func placeholderDuration(model: AudioModelConfig, params: AudioGenerationParams) -> Double {
        if let secs = params.durationSeconds { return Double(secs) }
        return model.category == .music
            ? Defaults.audioMusicDurationSeconds
            : Defaults.audioTTSDurationSeconds
    }

    @MainActor
    static func make(
        genInput baseInput: GenerationInput,
        model: AudioModelConfig,
        params: AudioGenerationParams,
        name: String? = nil,
        folderId: String? = nil,
        references: [MediaAsset] = [],
        trimmedSourceOverride: TrimmedSource? = nil
    ) -> AudioGenerationSubmission {
        var genInput = baseInput
        if model.supportsReferences {
            let imageRefs = references.filter { $0.type == .image }
            let audioRefs = references.filter { $0.type == .audio }
            genInput.referenceImageAssetIds = imageRefs.isEmpty ? nil : imageRefs.map(\.id)
            genInput.referenceAudioAssetIds = audioRefs.isEmpty ? nil : audioRefs.map(\.id)
        }
        return AudioGenerationSubmission(
            genInput: genInput,
            model: model,
            params: params,
            placeholderDuration: placeholderDuration(model: model, params: params),
            name: name,
            folderId: folderId,
            references: references,
            trimmedSourceOverride: trimmedSourceOverride
        )
    }

    struct InputAssets {
        var imageRefs: [MediaAsset] = []
        var audioRefs: [MediaAsset] = []

        @MainActor
        var references: [MediaAsset] { imageRefs + audioRefs }

        @MainActor
        func validate(for model: AudioModelConfig) -> String? {
            if imageRefs.count > model.maxReferenceImages {
                return "\(model.displayName) accepts at most \(model.maxReferenceImages) image reference(s)."
            }
            if audioRefs.count > model.maxReferenceAudios {
                return "\(model.displayName) accepts at most \(model.maxReferenceAudios) audio references."
            }
            if model.referenceImagesAndAudiosExclusive,
               !imageRefs.isEmpty, !audioRefs.isEmpty {
                return "\(model.displayName) uses either image or audio references, not both."
            }
            if imageRefs.contains(where: { $0.type != .image }) {
                return "Image references must be image assets."
            }
            for asset in audioRefs {
                guard asset.type == .audio else {
                    return "Audio references must be audio assets."
                }
                if let maximum = model.maxReferenceAudioSeconds,
                   !asset.duration.isFinite || asset.duration <= 0 || asset.duration > maximum {
                    return "\(asset.name) must be valid audio no longer than \(Int(maximum)) seconds."
                }
                if let allowed = model.referenceAudioExtensions,
                   !allowed.contains(asset.url.pathExtension.lowercased()) {
                    return "\(asset.name) must be a WAV or MP3 file."
                }
            }
            return nil
        }
    }
}
