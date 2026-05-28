import Foundation

extension ToolExecutor {
    func generate(_ editor: EditorViewModel, _ args: [String: Any], type: ClipType) throws -> ToolResult {
        let prompt = try args.requireString("prompt")
        guard AccountService.shared.isPaid else {
            throw ToolError("Generation requires an active Palmier subscription. Tell the user to sign in and subscribe.")
        }
        switch type {
        case .video:
            guard let modelId = args.string("model") ?? VideoModelConfig.allModels.first?.id else {
                throw ToolError("Model catalog not loaded yet. Try again in a moment.")
            }
            guard let model = VideoModelConfig.allModels.first(where: { $0.id == modelId }) else {
                throw ToolError("Unknown model '\(modelId)'. Available: \(VideoModelConfig.allModels.map(\.id).joined(separator: ", "))")
            }
            return model.requiresSourceVideo
                ? try generateVideoEdit(editor, args, prompt: prompt, model: model)
                : try generateVideoText(editor, args, prompt: prompt, model: model)
        case .image:
            return try generateImage(editor, args, prompt: prompt)
        case .audio:
            return try generateAudio(editor, args, prompt: prompt)
        case .text:
            throw ToolError("Text generation is not wired through the generate tool.")
        }
    }

    private func generateVideoEdit(
        _ editor: EditorViewModel, _ args: [String: Any],
        prompt: String, model: VideoModelConfig
    ) throws -> ToolResult {
        guard let sourceRef = args.string("sourceVideoMediaRef") else {
            throw ToolError("Model '\(model.id)' requires 'sourceVideoMediaRef' pointing to a video asset.")
        }
        let sourceAsset = try asset(sourceRef, editor: editor, label: "Source video")

        var imageRefs: [MediaAsset] = []
        for id in args.stringArray("referenceImageMediaRefs") {
            imageRefs.append(try asset(id, editor: editor, label: "Reference image"))
        }

        if let err = model.validate(duration: 0, aspectRatio: "", resolution: nil) {
            throw ToolError(err)
        }
        let inputAssets = VideoGenerationSubmission.InputAssets(sourceVideo: sourceAsset, imageRefs: imageRefs)
        if let err = inputAssets.validate(for: model) {
            throw ToolError(err)
        }

        let genInput = GenerationInput(
            prompt: prompt, model: model.id, duration: Int(sourceAsset.duration.rounded()),
            aspectRatio: "", resolution: nil
        )
        let placeholderId = VideoGenerationSubmission.make(
            genInput: genInput,
            model: model,
            inputAssets: inputAssets,
            placeholderDuration: sourceAsset.duration > 0 ? sourceAsset.duration : 5,
            name: args.string("name"),
            folderId: sourceAsset.folderId,
            generateAudio: true
        ).submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor
        )
        return .ok("Edit started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), source: \(sourceAsset.name)")
    }

    private func generateVideoText(
        _ editor: EditorViewModel, _ args: [String: Any],
        prompt: String, model: VideoModelConfig
    ) throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }

        let duration = args.int("duration") ?? model.durations.first ?? 0
        let aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
        let resolution = args.string("resolution") ?? model.resolutions?.first

        if let err = model.validate(duration: duration, aspectRatio: aspectRatio, resolution: resolution) {
            throw ToolError(err)
        }

        var frameSlots: [MediaAsset] = []
        if let startRef = args.string("startFrameMediaRef") {
            frameSlots.append(try asset(startRef, editor: editor, label: "Start frame"))
        }
        if let endRef = args.string("endFrameMediaRef") {
            frameSlots.append(try asset(endRef, editor: editor, label: "End frame"))
        }

        func refs(_ argName: String, label: String) throws -> [MediaAsset] {
            try args.stringArray(argName).map { id in
                try asset(id, editor: editor, label: label)
            }
        }
        let imageRefs = try refs("referenceImageMediaRefs", label: "Image reference")
        let videoRefs = try refs("referenceVideoMediaRefs", label: "Video reference")
        let audioRefs = try refs("referenceAudioMediaRefs", label: "Audio reference")
        let inputAssets = VideoGenerationSubmission.InputAssets(
            frames: frameSlots,
            imageRefs: imageRefs,
            videoRefs: videoRefs,
            audioRefs: audioRefs
        )
        if let err = inputAssets.validate(for: model) {
            throw ToolError(err)
        }

        let imageRefCount = imageRefs.count
        let videoRefCount = videoRefs.count
        let audioRefCount = audioRefs.count
        let totalRefs = inputAssets.totalRefCount

        let genInput = GenerationInput(
            prompt: prompt, model: model.id, duration: duration,
            aspectRatio: aspectRatio, resolution: resolution
        )

        let folderId = try resolveFolderId(
            args, editor: editor, fallbackReferences: inputAssets.textToVideoReferences
        )
        let placeholderId = VideoGenerationSubmission.make(
            genInput: genInput,
            model: model,
            inputAssets: inputAssets,
            placeholderDuration: Double(max(1, duration)),
            name: args.string("name"),
            folderId: folderId,
            generateAudio: true
        ).submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor
        )
        let refSummary = totalRefs > 0
            ? ", refs: \(imageRefCount)img/\(videoRefCount)vid/\(audioRefCount)aud"
            : ""
        return .ok("Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), duration: \(duration)s, aspect: \(aspectRatio)\(refSummary)")
    }

    private func generateImage(
        _ editor: EditorViewModel, _ args: [String: Any], prompt: String
    ) throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }
        guard let modelId = args.string("model") ?? ImageModelConfig.allModels.first?.id else {
            throw ToolError("Model catalog not loaded yet. Try again in a moment.")
        }
        guard let model = ImageModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(ImageModelConfig.allModels.map(\.id).joined(separator: ", "))")
        }
        let aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
        let resolution = args.string("resolution") ?? model.resolutions?.first
        let quality = args.string("quality") ?? model.qualities?.last
        let refIds = args.stringArray("referenceMediaRefs")
        if let err = model.validate(
            aspectRatio: aspectRatio, resolution: resolution, quality: quality,
            imageRefCount: refIds.count, numImages: 1
        ) {
            throw ToolError(err)
        }
        let refs: [MediaAsset] = try refIds.map { id in
            let a = try asset(id, editor: editor, label: "Reference image")
            guard a.type == .image else {
                throw ToolError("referenceMediaRefs entry '\(id)' must be an image asset (got \(a.type.rawValue))")
            }
            return a
        }

        let genInput = GenerationInput(
            prompt: prompt, model: modelId, duration: 0,
            aspectRatio: aspectRatio, resolution: resolution, quality: quality
        )
        let folderId = try resolveFolderId(args, editor: editor, fallbackReferences: refs)
        let placeholderId = ImageGenerationSubmission.make(
            genInput: genInput,
            model: model,
            references: refs,
            name: args.string("name"),
            folderId: folderId
        ).submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor
        )
        return .ok("Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), aspect: \(aspectRatio)")
    }

    private func generateAudio(
        _ editor: EditorViewModel, _ args: [String: Any], prompt: String
    ) throws -> ToolResult {
        guard let modelId = args.string("model") ?? AudioModelConfig.allModels.first?.id else {
            throw ToolError("Model catalog not loaded yet. Try again in a moment.")
        }
        guard let model = AudioModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(AudioModelConfig.allModels.map(\.id).joined(separator: ", "))")
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespaces)
        let instrumental = args.bool("instrumental") ?? false
        let duration = args.int("duration")
        let params = AudioGenerationParams(
            prompt: trimmed,
            voice: model.voices != nil ? (args.string("voice") ?? model.defaultVoice) : nil,
            lyrics: model.supportsLyrics ? args.string("lyrics") : nil,
            styleInstructions: model.supportsStyleInstructions ? args.string("styleInstructions") : nil,
            instrumental: model.supportsInstrumental ? instrumental : false,
            durationSeconds: model.durations != nil ? duration : nil
        )
        if let err = model.validate(params: params) {
            throw ToolError(err)
        }

        let genInput = GenerationInput(
            prompt: trimmed,
            model: model.id,
            duration: model.durations != nil ? (duration ?? 0) : 0,
            aspectRatio: "",
            resolution: nil,
            voice: params.voice,
            lyrics: params.lyrics,
            styleInstructions: params.styleInstructions,
            instrumental: model.supportsInstrumental ? instrumental : nil
        )

        let folderId = try resolveFolderId(args, editor: editor)
        let placeholderId = AudioGenerationSubmission.make(
            genInput: genInput,
            model: model,
            params: params,
            name: args.string("name"),
            folderId: folderId
        ).submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor
        )
        return .ok("Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), category: \(model.category == .music ? "music" : "tts")")
    }

    func upscaleMedia(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .video || asset.type == .image else {
            throw ToolError("Upscale supports video and image assets only (got \(asset.type.rawValue))")
        }
        guard AccountService.shared.isPaid else {
            throw ToolError("Upscale requires an active Palmier subscription. Tell the user to sign in and subscribe.")
        }

        let available = UpscaleModelConfig.models(for: asset.type)
        let model: UpscaleModelConfig
        if let requested = args.string("model") {
            guard let match = available.first(where: { $0.id == requested }) else {
                let ids = available.map(\.id).joined(separator: ", ")
                throw ToolError("Model '\(requested)' does not support \(asset.type.rawValue). Available: \(ids)")
            }
            model = match
        } else {
            guard let first = available.first else {
                throw ToolError("No upscaler available for \(asset.type.rawValue)")
            }
            model = first
        }

        guard let placeholderId = EditSubmitter.submitUpscale(
            asset: asset, model: model, editor: editor
        ) else {
            throw ToolError("Failed to start upscale")
        }
        return .ok("Upscale started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), source: \(asset.name)")
    }

    func listModels(_ args: [String: Any]) -> ToolResult {
        let filter = args.string("type")
        var out: [[String: Any]] = []
        if filter == nil || filter == "video" {
            out += VideoModelConfig.allModels.map { Self.videoModelInfo($0, includeType: true) }
        }
        if filter == nil || filter == "image" {
            out += ImageModelConfig.allModels.map { Self.imageModelInfo($0, includeType: true) }
        }
        if filter == nil || filter == "audio" {
            out += AudioModelConfig.allModels.map { Self.audioModelInfo($0) }
        }
        if filter == nil || filter == "upscale" {
            out += UpscaleModelConfig.allModels.map { Self.upscaleModelInfo($0) }
        }
        let body: [String: Any] = [
            "models": out,
            "loaded": ModelCatalog.shared.isLoaded,
        ]
        guard let json = Self.jsonString(body) else { return .error("Failed to encode model list") }
        return .ok(json)
    }

    nonisolated static func videoModelInfo(_ m: VideoModelConfig, includeType: Bool = false) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "durations": m.durations, "aspectRatios": m.aspectRatios,
            "supportsFirstFrame": m.supportsFirstFrame,
            "supportsLastFrame": m.supportsLastFrame,
            "supportsReferences": m.supportsReferences,
        ]
        if includeType { info["type"] = "video" }
        if let r = m.resolutions { info["resolutions"] = r }
        if m.supportsReferences {
            if m.maxReferenceImages > 0 { info["maxReferenceImages"] = m.maxReferenceImages }
            if m.maxReferenceVideos > 0 { info["maxReferenceVideos"] = m.maxReferenceVideos }
            if m.maxReferenceAudios > 0 { info["maxReferenceAudios"] = m.maxReferenceAudios }
            if let total = m.maxTotalReferences { info["maxTotalReferences"] = total }
            if let s = m.maxCombinedVideoRefSeconds { info["maxCombinedVideoRefSeconds"] = Int(s) }
            if let s = m.maxCombinedAudioRefSeconds { info["maxCombinedAudioRefSeconds"] = Int(s) }
            if m.framesAndReferencesExclusive { info["framesAndReferencesExclusive"] = true }
            info["referenceTagNoun"] = m.referenceTagNoun
        }
        return info
    }

    nonisolated static func imageModelInfo(_ m: ImageModelConfig, includeType: Bool = false) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "aspectRatios": m.aspectRatios,
            "supportsImageReference": m.supportsImageReference,
        ]
        if includeType { info["type"] = "image" }
        if let r = m.resolutions { info["resolutions"] = r }
        if let q = m.qualities { info["qualities"] = q }
        return info
    }

    nonisolated static func audioModelInfo(_ m: AudioModelConfig) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "type": "audio",
            "category": m.category == .music ? "music" : "tts",
            "minPromptLength": m.minPromptLength,
            "supportsLyrics": m.supportsLyrics,
            "supportsInstrumental": m.supportsInstrumental,
            "supportsStyleInstructions": m.supportsStyleInstructions,
        ]
        if let voices = m.voices {
            info["voicesSample"] = Array(voices.prefix(3))
            info["voiceCount"] = voices.count
        }
        if let defaultVoice = m.defaultVoice { info["defaultVoice"] = defaultVoice }
        if let durations = m.durations { info["durations"] = durations }
        return info
    }

    nonisolated static func upscaleModelInfo(_ m: UpscaleModelConfig) -> [String: Any] {
        [
            "id": m.id, "displayName": m.displayName,
            "type": "upscale",
            "speed": m.speed,
            "supportedTypes": m.supportedTypes.map(\.rawValue).sorted(),
        ]
    }
}
