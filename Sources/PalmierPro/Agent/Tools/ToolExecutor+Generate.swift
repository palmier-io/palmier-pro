import AppKit
import AVFoundation
import Foundation

extension ToolExecutor {
    private var canUsePaidModels: Bool { AccountService.shared.isPaid }
    private func modelAvailable(paidOnly: Bool) -> Bool { canUsePaidModels || !paidOnly }

    private func requirePlan(for modelId: String, paidOnly: Bool) throws {
        if paidOnly && !canUsePaidModels {
            throw ToolError(
                "Model '\(modelId)' requires a paid plan. Pick a free model from list_models, "
                + "or tell the user to subscribe."
            )
        }
    }

    private func draftMode(_ args: [String: Any], model: VideoModelConfig) throws -> Bool {
        let draft = args.bool("draft") ?? false
        if draft && !model.supportsDraft {
            throw ToolError("Model '\(model.id)' does not support draft generation.")
        }
        return draft
    }

    private func defaultModelId(_ ids: [(id: String, paidOnly: Bool)], kind: String) throws -> String {
        guard !ids.isEmpty else {
            throw ToolError("Model catalog not loaded yet. Try again in a moment.")
        }
        guard let match = ids.first(where: { modelAvailable(paidOnly: $0.paidOnly) }) else {
            throw ToolError("No \(kind) model is available on the current plan. Tell the user to subscribe.")
        }
        return match.id
    }

    func generate(_ editor: EditorViewModel, _ args: [String: Any], type: ClipType) throws -> ToolResult {
        let prompt = args["prompt"] == nil ? "" : try args.requireString("prompt")
        guard AccountService.shared.isSignedIn else {
            throw ToolError("Generation requires signing in to Palmier. Tell the user to sign in.")
        }
        guard AccountService.shared.hasCredits else {
            throw ToolError("Out of credits. Tell the user to add credits or subscribe to keep generating.")
        }
        switch type {
        case .sequence:
            throw ToolError("Cannot generate a sequence. Sequences are timelines.")
        case .video:
            if let mediaRef = args.string("enhanceDraftMediaRef") {
                let draft = try asset(mediaRef, editor: editor, label: "Draft")
                guard let placeholderId = editor.generationService.enhanceDraft(
                    asset: draft,
                    editor: editor
                ) else {
                    throw ToolError("Asset '\(mediaRef)' is not a completed enhanceable draft.")
                }
                let input = draft.generationInput
                let model = input.flatMap { id in VideoModelConfig.allModels.first { $0.id == id.model } }
                return generationPreviewReceipt(
                    message: "Draft enhancement started. Placeholder asset ID: \(placeholderId)",
                    mediaRef: placeholderId,
                    kind: "video",
                    prompt: input?.prompt ?? "",
                    displayName: model?.displayName ?? "Enhance draft",
                    iconKey: model?.entry.providerIconKey,
                    aspectRatio: input?.aspectRatio,
                    duration: input?.duration,
                    resolution: input?.resolution,
                    credits: input.flatMap { CostEstimator.cost(for: $0) }
                )
            }
            let modelId = try args.string("model") ?? defaultModelId(
                VideoModelConfig.allModels.map { (id: $0.id, paidOnly: $0.paidOnly) }, kind: "video")
            guard let model = VideoModelConfig.allModels.first(where: { $0.id == modelId }) else {
                throw ToolError("Unknown model '\(modelId)'. Available: \(VideoModelConfig.allModels.map(\.id).joined(separator: ", "))")
            }
            try requirePlan(for: model.id, paidOnly: model.paidOnly)
            let hasSourceVideo = args.string("sourceVideoMediaRef") != nil
            if hasSourceVideo && !model.supportsSourceVideo {
                throw ToolError("Model '\(model.id)' does not accept a source video.")
            }
            if model.requiresSourceVideo || hasSourceVideo {
                return try generateVideoEdit(editor, args, prompt: prompt, model: model)
            }
            return try generateVideoText(editor, args, prompt: prompt, model: model)
        case .image:
            return try generateImage(editor, args, prompt: prompt)
        case .audio:
            throw ToolError("internal: audio generation is dispatched via the async path")
        case .text:
            throw ToolError("Text generation is not wired through the generate tool.")
        case .lottie:
            throw ToolError("Lottie animations aren't generated through this tool.")
        case .subtitle:
            throw ToolError("Subtitle files aren't generated. Import an SRT or WebVTT file with import_media.")
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
        let trimmed = try trimmedSource(args, editor: editor, source: sourceAsset)

        let imageRefs = try referenceAssets(
            args, key: "referenceImageMediaRefs", label: "Reference image", editor: editor)
        let videoRefs = try referenceAssets(
            args, key: "referenceVideoMediaRefs", label: "Reference video", editor: editor)
        let audioRefs = try referenceAssets(
            args, key: "referenceAudioMediaRefs", label: "Reference audio", editor: editor)

        let inputAssets = VideoGenerationSubmission.InputAssets(
            sourceVideo: sourceAsset,
            imageRefs: imageRefs,
            videoRefs: videoRefs,
            audioRefs: audioRefs
        )
        if let err = inputAssets.validate(for: model) {
            throw ToolError(err)
        }

        let sourceVideoDuration = trimmed?.durationSeconds ?? sourceAsset.resolvedDuration
        let draft = try draftMode(args, model: model)
        let duration: Int
        if model.usesOutputDuration {
            duration = args.int("duration") ?? model.durations.first ?? 0
        } else {
            guard let billingDuration = model.billingDurationSeconds(
                sourceVideoDuration: sourceVideoDuration,
                sourceAudioDuration: audioRefs.first?.resolvedDuration
            ) else {
                throw ToolError(model.isLipSync
                    ? "Replacement audio has an invalid duration."
                    : "Source video has an invalid duration.")
            }
            duration = billingDuration
        }
        let aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
        let resolution = draft
            ? VideoModelConfig.draftResolution
            : (args.string("resolution") ?? model.resolutions?.first)
        if let error = model.validateSourceDuration(sourceVideoDuration)
            ?? model.validate(
                duration: model.usesOutputDuration ? duration : 0,
                aspectRatio: model.usesOutputDuration ? aspectRatio : "",
                resolution: model.usesOutputDuration ? resolution : nil
            ) {
            throw ToolError(error)
        }
        let genInput = GenerationInput(
            prompt: prompt, model: model.id,
            duration: duration,
            aspectRatio: aspectRatio, resolution: resolution,
            draft: draft,
            usesSourceVideo: true
        )
        let placeholderId = VideoGenerationSubmission.make(
            genInput: genInput,
            model: model,
            inputAssets: inputAssets,
            placeholderDuration: model.usesOutputDuration
                ? Double(max(1, duration))
                : sourceVideoDuration,
            trimmedSourceOverride: trimmed,
            name: args.string("name"),
            folderId: sourceAsset.folderId,
            generateAudio: true
        ).submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor
        )
        let draftSummary = draft ? ", draft: true" : ""
        return generationPreviewReceipt(
            message: "Edit started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), source: \(sourceAsset.name)\(draftSummary)",
            mediaRef: placeholderId,
            kind: "video",
            prompt: prompt,
            displayName: model.displayName,
            iconKey: model.entry.providerIconKey,
            aspectRatio: aspectRatio,
            duration: duration,
            resolution: resolution,
            credits: CostEstimator.cost(for: genInput)
        )
    }

    private func generateVideoText(
        _ editor: EditorViewModel, _ args: [String: Any],
        prompt: String, model: VideoModelConfig
    ) throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }

        let draft = try draftMode(args, model: model)
        let duration = args.int("duration") ?? model.durations.first ?? 0
        let aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
        let resolution = draft
            ? VideoModelConfig.draftResolution
            : (args.string("resolution") ?? model.resolutions?.first)
        if let error = model.validate(
            duration: duration,
            aspectRatio: aspectRatio,
            resolution: resolution
        ) {
            throw ToolError(error)
        }

        var frameSlots: [MediaAsset] = []
        if let startRef = args.string("startFrameMediaRef") {
            frameSlots.append(try asset(startRef, editor: editor, label: "Start frame"))
        }
        if let endRef = args.string("endFrameMediaRef") {
            frameSlots.append(try asset(endRef, editor: editor, label: "End frame"))
        }

        let imageRefs = try referenceAssets(
            args, key: "referenceImageMediaRefs", label: "Image reference", editor: editor)
        let videoRefs = try referenceAssets(
            args, key: "referenceVideoMediaRefs", label: "Video reference", editor: editor)
        let audioRefs = try referenceAssets(
            args, key: "referenceAudioMediaRefs", label: "Audio reference", editor: editor)
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
            aspectRatio: aspectRatio, resolution: resolution,
            draft: draft
        )

        let folderId = try resolveFolder(
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
        let draftSummary = draft ? ", draft: true" : ""
        return generationPreviewReceipt(
            message: "Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), duration: \(duration)s, aspect: \(aspectRatio)\(refSummary)\(draftSummary)",
            mediaRef: placeholderId,
            kind: "video",
            prompt: prompt,
            displayName: model.displayName,
            iconKey: model.entry.providerIconKey,
            aspectRatio: aspectRatio,
            duration: duration,
            resolution: resolution,
            credits: CostEstimator.cost(for: genInput)
        )
    }

    private func referenceAssets(
        _ args: [String: Any],
        key: String,
        label: String,
        editor: EditorViewModel
    ) throws -> [MediaAsset] {
        try args.stringArray(key).map { id in
            try asset(id, editor: editor, label: label)
        }
    }

    private func generateImage(
        _ editor: EditorViewModel, _ args: [String: Any], prompt: String
    ) throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }
        let modelId = try args.string("model") ?? defaultModelId(
            ImageModelConfig.allModels.map { (id: $0.id, paidOnly: $0.paidOnly) }, kind: "image")
        guard let model = ImageModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(ImageModelConfig.allModels.map(\.id).joined(separator: ", "))")
        }
        try requirePlan(for: model.id, paidOnly: model.paidOnly)
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
        let folderId = try resolveFolder(args, editor: editor, fallbackReferences: refs)
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
        return generationPreviewReceipt(
            message: "Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), aspect: \(aspectRatio)",
            mediaRef: placeholderId,
            kind: "image",
            prompt: prompt,
            displayName: model.displayName,
            iconKey: model.entry.providerIconKey,
            aspectRatio: aspectRatio,
            resolution: resolution,
            credits: CostEstimator.cost(for: genInput)
        )
    }

    func generateAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        guard AccountService.shared.isSignedIn else {
            throw ToolError("Generation requires signing in to Palmier. Tell the user to sign in.")
        }
        guard AccountService.shared.hasCredits else {
            throw ToolError("Out of credits. Tell the user to add credits or subscribe to keep generating.")
        }
        let modelId = try args.string("model") ?? defaultModelId(
            AudioModelConfig.allModels.map { (id: $0.id, paidOnly: $0.paidOnly) }, kind: "audio")
        guard let model = AudioModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(AudioModelConfig.allModels.map(\.id).joined(separator: ", "))")
        }
        try requirePlan(for: model.id, paidOnly: model.paidOnly)

        let prompt = (args.string("prompt") ?? "").trimmingCharacters(in: .whitespaces)
        let inputAssets = AudioGenerationSubmission.InputAssets(
            imageRefs: try args.stringArray("referenceImageMediaRefs").map {
                try asset($0, editor: editor, label: "Image reference")
            },
            audioRefs: try args.stringArray("referenceAudioMediaRefs").map {
                try asset($0, editor: editor, label: "Audio reference")
            }
        )
        if let error = inputAssets.validate(for: model) {
            throw ToolError(error)
        }
        let acceptsVideo = model.inputs.contains(.video)
        let sourceMediaRef = args.string("sourceMediaRef")
            ?? args.string("videoSourceMediaRef")
        var sourceAsset: MediaAsset?
        var videoURL: String?
        var spanSeconds: Double?
        var placementStartFrame: Int?   // set when a timeline span is given -> auto-place on the timeline
        if let ref = sourceMediaRef {
            let candidate = try asset(ref, editor: editor, label: "Source media")
            if args.string("sourceMediaRef") == nil, candidate.type != .video {
                throw ToolError("videoSourceMediaRef must be a video asset (got \(candidate.type.rawValue)).")
            }
            guard model.acceptsSource(candidate.type) else {
                throw ToolError("Model '\(model.id)' does not accept \(candidate.type.rawValue) source media.")
            }
            if model.usesSourceURL, candidate.type == .video, !candidate.hasAudio {
                throw ToolError("\(model.displayName) requires source video with an audio track.")
            }
            if let err = model.validate(spanSeconds: candidate.duration) {
                throw ToolError(err)
            }
            sourceAsset = candidate
            spanSeconds = candidate.duration
        } else if let start = args.int("videoSourceStartFrame"), let end = args.int("videoSourceEndFrame") {
            guard acceptsVideo else {
                throw ToolError("Model '\(model.id)' does not accept a video input (see list_models 'inputs').")
            }
            guard !model.usesSourceURL else {
                throw ToolError("Use sourceMediaRef for \(model.displayName).")
            }
            guard start >= 0, end > start else {
                throw ToolError("videoSourceEndFrame must be greater than videoSourceStartFrame (>= 0).")
            }
            if let err = model.validate(spanSeconds: Double(end - start) / Double(max(1, editor.timeline.fps))) {
                throw ToolError(err)
            }
            let mp4 = try await TimelineRenderer.render(
                timeline: editor.timeline, resolver: editor.mediaResolver,
                resolveTimeline: editor.timelineResolver(),
                missingMediaRefs: editor.missingMediaRefs,
                startFrame: start, frameCount: end - start,
                shortSide: 240, includeAudio: false,
                preset: AVAssetExportPresetLowQuality
            )
            defer { try? FileManager.default.removeItem(at: mp4) }
            videoURL = try await GenerationBackend.uploadReference(fileURL: mp4, contentType: "video/mp4")
            spanSeconds = Double(end - start) / Double(max(1, editor.timeline.fps))
            placementStartFrame = start
        }

        if model.acceptsSourceMedia && !model.inputs.contains(.text)
            && sourceAsset == nil && videoURL == nil {
            throw ToolError("Model '\(model.id)' needs source media. Provide sourceMediaRef.")
        }

        let instrumental = args.bool("instrumental") ?? false
        let requestedDurationSeconds = args.int("duration")
        let sourceDurationSeconds = spanSeconds.map { max(1, Int($0.rounded())) }
        let durationSeconds = model.usesSourceURL
            ? sourceDurationSeconds
            : (requestedDurationSeconds ?? sourceDurationSeconds)
        let params = AudioGenerationParams(
            prompt: prompt,
            voice: model.voices != nil ? (args.string("voice") ?? model.defaultVoice) : nil,
            lyrics: model.supportsLyrics ? args.string("lyrics") : nil,
            styleInstructions: model.supportsStyleInstructions ? args.string("styleInstructions") : nil,
            instrumental: model.supportsInstrumental ? instrumental : false,
            durationSeconds: durationSeconds,
            videoURL: videoURL,
            sourceURL: nil,
            targetLanguage: model.targetLanguages != nil
                ? args.string("targetLanguage") : nil,
            multilingual: model.supportsMultilingual
                ? (args.bool("multilingual") ?? false) : nil
        )
        if let err = model.validate(params: params) {
            throw ToolError(err)
        }

        var genInput = GenerationInput(
            prompt: prompt,
            model: model.id,
            duration: durationSeconds ?? 0,
            aspectRatio: "",
            resolution: nil,
            voice: params.voice,
            lyrics: params.lyrics,
            styleInstructions: params.styleInstructions,
            instrumental: model.supportsInstrumental ? instrumental : nil,
            targetLanguage: params.targetLanguage,
            multilingual: params.multilingual
        )
        if let sourceAsset {
            genInput.audioInput = sourceAsset.type == .video
                ? AudioModelConfig.Input.video.rawValue
                : AudioModelConfig.Input.audio.rawValue
        } else {
            genInput.audioInput = videoURL == nil
                ? AudioModelConfig.Input.text.rawValue
                : AudioModelConfig.Input.video.rawValue
        }
        if let sourceAsset {
            genInput.setAudioSourceAsset(sourceAsset)
        }

        let sourceReferences = sourceAsset.map { [$0] } ?? []
        let folderId = try resolveFolder(
            args,
            editor: editor,
            fallbackReferences: sourceReferences + inputAssets.references
        )
        let submission = AudioGenerationSubmission.make(
            genInput: genInput,
            model: model,
            params: params,
            name: args.string("name"),
            folderId: folderId,
            references: model.supportsReferences ? inputAssets.references : sourceReferences
        )

        if let startFrame = placementStartFrame, let sourceSpan = spanSeconds {
            let outputSpan = requestedDurationSeconds.map(Double.init) ?? sourceSpan
            let placeholderId = editor.undo.perform("Add \(model.category.label) (Agent)") {
                let placeholderId = submission.submit(
                    service: editor.generationService,
                    projectURL: editor.projectURL,
                    editor: editor,
                    onComplete: { asset in
                        editor.finalizeGeneratingClip(placeholderId: asset.id, asset: asset)
                    }
                )
                editor.placeGeneratingAudioClip(
                    placeholderId: placeholderId, startFrame: startFrame,
                    spanSeconds: outputSpan, actionName: "Add \(model.category.label)"
                )
                return placeholderId
            }
            return generationPreviewReceipt(
                message: "Generation started and placed on the timeline at frame \(startFrame). Placeholder asset ID: \(placeholderId). Model: \(model.displayName), \(model.category.label) (scored from video).",
                mediaRef: placeholderId,
                kind: "audio",
                prompt: prompt,
                displayName: model.displayName,
                iconKey: model.entry.providerIconKey,
                duration: durationSeconds,
                credits: CostEstimator.cost(for: genInput)
            )
        }

        let placeholderId = submission.submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor
        )
        let sourceNote = sourceAsset != nil || videoURL != nil ? " (from source media)" : ""
        return generationPreviewReceipt(
            message: "Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), \(model.category.label)\(sourceNote). Place it with add_clips.",
            mediaRef: placeholderId,
            kind: "audio",
            prompt: prompt,
            displayName: model.displayName,
            iconKey: model.entry.providerIconKey,
            duration: durationSeconds,
            credits: CostEstimator.cost(for: genInput)
        )
    }

    func upscaleMedia(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .video || asset.type == .image else {
            throw ToolError("Upscale supports video and image assets only (got \(asset.type.rawValue))")
        }
        guard asset.sourceWidth != nil, asset.sourceHeight != nil else {
            throw ToolError("Source dimensions are not available yet. Poll get_media until the asset is ready.")
        }
        guard asset.type != .video || asset.sourceFPS != nil else {
            throw ToolError("Source FPS is not available yet. Poll get_media until the asset is ready.")
        }
        guard AccountService.shared.isSignedIn else {
            throw ToolError("Upscale requires signing in to Palmier. Tell the user to sign in.")
        }
        guard AccountService.shared.hasCredits else {
            throw ToolError("Out of credits. Tell the user to add credits or subscribe to keep generating.")
        }

        let available = UpscaleModelConfig.models(for: asset.type)
        let model: UpscaleModelConfig
        if let requested = args.string("model") {
            guard let match = available.first(where: { $0.id == requested }) else {
                let ids = available.map(\.id).joined(separator: ", ")
                throw ToolError("Model '\(requested)' does not support \(asset.type.rawValue). Available: \(ids)")
            }
            try requirePlan(for: match.id, paidOnly: match.paidOnly)
            guard match.supports(source: asset) else {
                throw ToolError("Model '\(requested)' is not compatible with this source's resolution or frame rate.")
            }
            model = match
        } else {
            guard let first = available.first(where: {
                modelAvailable(paidOnly: $0.paidOnly) && $0.supports(source: asset)
            }) else {
                throw ToolError("No compatible upscaler is available for this \(asset.type.rawValue) on the current plan.")
            }
            model = first
        }

        let settings = try resolvedUpscaleSettings(args["settings"], model: model, source: asset)
        let trimmed = try trimmedSource(args, editor: editor, source: asset)
        guard let placeholderId = EditSubmitter.submitUpscale(
            asset: asset, model: model, editor: editor, settings: settings, trimmedSource: trimmed
        ) else {
            throw ToolError("Failed to start upscale")
        }
        return .ok("Upscale started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), source: \(asset.name)\(trimmed != nil ? " (trimmed range)" : "")")
    }

    private func resolvedUpscaleSettings(
        _ raw: Any?, model: UpscaleModelConfig, source: MediaAsset
    ) throws -> UpscaleSettings {
        let supplied: [String: Any]
        if let raw {
            guard let dictionary = raw as? [String: Any] else {
                throw ToolError("settings must be an object")
            }
            supplied = dictionary
        } else {
            supplied = [:]
        }

        var resolved = model.normalizedSettings(model.defaultSettings, source: source)
        for (id, rawValue) in supplied {
            if let setting = model.selectSettings.first(where: { $0.id == id }) {
                let options = model.availableOptions(for: setting, source: source)
                guard let value = rawValue as? String,
                      options.contains(where: { $0.value == value }) else {
                    throw ToolError("Unsupported \(id). Available: \(options.map(\.value).joined(separator: ", "))")
                }
                resolved.selections[id] = value
            } else if let setting = model.numericSettings.first(where: { $0.id == id }) {
                guard let value = ["value": rawValue].double("value"), value.isFinite,
                      (setting.minimum...setting.maximum).contains(value) else {
                    throw ToolError("\(id) must be between \(setting.minimum) and \(setting.maximum)")
                }
                resolved.numbers[id] = value
            } else if model.toggleSettings.contains(where: { $0.id == id }) {
                guard isJSONBoolean(rawValue), let value = rawValue as? Bool else {
                    throw ToolError("\(id) must be true or false")
                }
                resolved.toggles[id] = value
            } else {
                let valid = (model.selectSettings.map(\.id)
                    + model.numericSettings.map(\.id)
                    + model.toggleSettings.map(\.id)).joined(separator: ", ")
                throw ToolError("Unknown upscale setting '\(id)'. Available: \(valid)")
            }
        }
        return resolved
    }

    private func trimmedSource(
        _ args: [String: Any], editor: EditorViewModel, source: MediaAsset
    ) throws -> TrimmedSource? {
        guard let clipId = args.string("sourceClipId") else { return nil }
        guard let clip = editor.clipFor(id: clipId) else {
            throw ToolError("sourceClipId not found: \(clipId)")
        }
        guard clip.mediaRef == source.id else {
            throw ToolError("sourceClipId \(clipId) references a different asset than the source")
        }
        guard source.type == .video else {
            throw ToolError("sourceClipId only applies to video sources")
        }
        guard clip.trimStartFrame > 0 || clip.trimEndFrame > 0 else { return nil }
        return TrimmedSource(
            sourceURL: source.url,
            trimStartFrame: clip.trimStartFrame,
            trimEndFrame: clip.trimEndFrame,
            sourceFramesConsumed: clip.sourceFramesConsumed,
            fps: editor.timeline.fps
        )
    }

    func listModels(_ args: [String: Any]) -> ToolResult {
        let filter = args.string("type")
        var out: [[String: Any]] = []
        if filter == nil || filter == "video" {
            out += VideoModelConfig.allModels
                .filter { modelAvailable(paidOnly: $0.paidOnly) }
                .map { Self.videoModelInfo($0, includeType: true) }
        }
        if filter == nil || filter == "image" {
            out += ImageModelConfig.allModels
                .filter { modelAvailable(paidOnly: $0.paidOnly) }
                .map { Self.imageModelInfo($0, includeType: true) }
        }
        if filter == nil || filter == "audio" {
            out += AudioModelConfig.allModels
                .filter { modelAvailable(paidOnly: $0.paidOnly) }
                .map { Self.audioModelInfo($0) }
        }
        if filter == nil || filter == "upscale" {
            out += UpscaleModelConfig.allModels
                .filter { modelAvailable(paidOnly: $0.paidOnly) }
                .map { Self.upscaleModelInfo($0) }
        }
        let body: [String: Any] = [
            "models": out,
            "loaded": ModelCatalog.shared.isLoaded,
        ]
        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(body, toPlaces: 3)) else {
            return .error("Failed to encode model list")
        }
        return .ok(json)
    }

    nonisolated static func videoModelInfo(_ m: VideoModelConfig, includeType: Bool = false) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "durations": m.durations, "aspectRatios": m.aspectRatios,
            "supportsFirstFrame": m.supportsFirstFrame,
            "supportsLastFrame": m.supportsLastFrame,
            "supportsReferences": m.supportsReferences,
            "supportsPrompt": m.supportsPrompt,
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
        if m.requiresSourceVideo { info["requiresSourceVideo"] = true }
        if m.supportsSourceVideo { info["supportsSourceVideo"] = true }
        if let seconds = m.maxSourceVideoSeconds { info["maxSourceVideoSeconds"] = seconds }
        if m.requiresReferenceImage { info["requiresReferenceImage"] = true }
        if m.requiresReferenceAudio { info["requiresReferenceAudio"] = true }
        if m.usesOutputDuration { info["usesOutputDuration"] = true }
        if let rate = m.draftCreditsPerSecond {
            info["supportsDraft"] = true
            info["draftResolution"] = VideoModelConfig.draftResolution
            info["draftCreditsPerSecond"] = rate
            if let enhanceRate = m.draftEnhanceCreditsPerSecond {
                info["draftEnhanceCreditsPerSecond"] = enhanceRate
            }
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
            "category": m.category.rawValue,
            "inputs": m.inputs.map(\.rawValue),
            "minPromptLength": m.minPromptLength,
            "supportsMultilingual": m.supportsMultilingual,
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
        if m.maxReferenceImages > 0 { info["maxReferenceImages"] = m.maxReferenceImages }
        if m.maxReferenceAudios > 0 { info["maxReferenceAudios"] = m.maxReferenceAudios }
        if let maxReferenceAudioSeconds = m.maxReferenceAudioSeconds {
            info["maxReferenceAudioSeconds"] = maxReferenceAudioSeconds
        }
        if let referenceAudioExtensions = m.referenceAudioExtensions {
            info["referenceAudioExtensions"] = Array(referenceAudioExtensions).sorted()
        }
        if m.referenceImagesAndAudiosExclusive {
            info["referenceImagesAndAudiosExclusive"] = true
        }
        if m.acceptsSourceMedia {
            info["minSeconds"] = m.minSeconds
            info["maxSeconds"] = m.maxSeconds
        }
        if let targetLanguages = m.targetLanguages {
            info["targetLanguages"] = targetLanguages
        }
        return info
    }

    nonisolated static func upscaleModelInfo(_ m: UpscaleModelConfig) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "type": "upscale",
            "speed": m.speed,
            "supportedTypes": m.supportedTypes.map(\.rawValue).sorted(),
        ]
        if let description = m.description { info["description"] = description }
        if let factor = m.caps.maximumUpscaleFactor { info["maximumUpscaleFactor"] = factor }

        let selects: [[String: Any]] = m.selectSettings.map { setting in
            let options: [[String: Any]] = setting.options.map { option in
                var value: [String: Any] = ["value": option.value, "label": option.label]
                if let description = option.description { value["description"] = description }
                if let group = option.group { value["group"] = group }
                if let description = option.groupDescription { value["groupDescription"] = description }
                return value
            }
            return [
                "id": setting.id, "label": setting.label, "type": "select",
                "default": setting.defaultValue, "options": options,
            ]
        }
        let numbers: [[String: Any]] = m.numericSettings.map {
            [
                "id": $0.id, "label": $0.label, "type": "number",
                "minimum": $0.minimum, "maximum": $0.maximum, "step": $0.step,
            ]
        }
        let toggles: [[String: Any]] = m.toggleSettings.map {
            [
                "id": $0.id, "label": $0.label, "type": "boolean",
                "default": $0.defaultValue,
            ]
        }
        info["settings"] = selects + numbers + toggles
        return info
    }

    private func generationPreviewReceipt(
        message: String,
        mediaRef: String,
        kind: String,
        prompt: String,
        displayName: String,
        iconKey: String?,
        aspectRatio: String? = nil,
        duration: Int? = nil,
        resolution: String? = nil,
        credits: Int? = nil
    ) -> ToolResult {
        guard Analytics.origin?.source == "mcp" else { return .ok(message) }
        let group = registerMCPPreviewBurst(kind: kind, mediaRef: mediaRef)
        var payload: [String: Any] = [
            "kind": kind,
            "mediaRef": mediaRef,
            "message": message,
            "model": displayName,
            "previewUri": MCPPreviewApp.previewResourceURI(mediaRef: mediaRef),
            "prompt": prompt,
            "status": "generating",
            "groupRole": group.role,
            "groupMembers": group.members,
        ]
        if let iconKey, !iconKey.isEmpty { payload["modelIconKey"] = iconKey }
        if let aspectRatio, !aspectRatio.isEmpty { payload["aspectRatio"] = aspectRatio }
        if let duration, duration > 0 { payload["duration"] = duration }
        if let resolution, !resolution.isEmpty { payload["resolution"] = resolution }
        if let credits { payload["credits"] = credits }
        return .ok(Self.jsonString(payload) ?? message)
    }

    static let groupedPreviewKinds: Set<String> = ["image", "video"]

    func registerMCPPreviewBurst(kind: String, mediaRef: String) -> (role: String, members: [String]) {
        if Self.groupedPreviewKinds.contains(kind), mcpPreviewBurstKind == kind {
            mcpPreviewBurstMediaRefs.append(mediaRef)
        } else {
            mcpPreviewBurstKind = kind
            mcpPreviewBurstMediaRefs = [mediaRef]
        }
        let members = mcpPreviewBurstMediaRefs
        let isMember = Self.groupedPreviewKinds.contains(kind)
            && members.count > 1
            && mediaRef != members.first
        if isMember, let host = members.first {
            NotificationCenter.default.post(name: .generationAssetDidChange, object: host)
        }
        return (isMember ? "member" : "host", members)
    }

    func mcpPreviewGroup(for mediaRef: String) -> (role: String, members: [String])? {
        guard let index = mcpPreviewBurstMediaRefs.firstIndex(of: mediaRef) else { return nil }
        let groups = mcpPreviewBurstKind.map { Self.groupedPreviewKinds.contains($0) } ?? false
        let members = groups ? mcpPreviewBurstMediaRefs : [mediaRef]
        let isMember = groups && members.count > 1 && index > 0
        return (isMember ? "member" : "host", members)
    }

    func getGenerationPreview(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["mediaRef", "includeMedia"], path: "get_generation_preview")
        let mediaRef = try args.requireString("mediaRef")
        let includeMedia = args.bool("includeMedia") ?? false
        return .ok(await generationPreviewJSON(mediaRef: mediaRef, includeMedia: includeMedia, editor: editor))
    }

    func revealGenerationMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["mediaRef"], path: "reveal_generation_media")
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        let url = asset.url
        let exists = await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: url.path)
        }.value
        guard exists else {
            throw ToolError("Generated file is not on disk yet.")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return .ok(#"{"revealed":true}"#)
    }

    func generationPreviewJSON(
        mediaRef: String,
        includeMedia: Bool = false,
        editor: EditorViewModel? = nil
    ) async -> String {
        if let json = await timelinePreviewJSON(mediaRef: mediaRef, includeMedia: includeMedia) {
            return json
        }
        let payload = await generationPreviewPayload(
            mediaRef: mediaRef,
            includeMedia: includeMedia,
            editor: editor ?? self.editor
        )
        return Self.jsonString(payload) ?? #"{"status":"missing"}"#
    }

    private func generationPreviewPayload(
        mediaRef: String,
        includeMedia: Bool,
        editor: EditorViewModel?
    ) async -> [String: Any] {
        guard let editor, let asset = editor.mediaAssets.first(where: { $0.id == mediaRef }) else {
            return ["mediaRef": mediaRef, "status": "missing"]
        }
        var payload: [String: Any] = [
            "kind": asset.type.rawValue,
            "mediaRef": mediaRef,
        ]
        if let group = mcpPreviewGroup(for: mediaRef) {
            payload["groupRole"] = group.role
            payload["groupMembers"] = group.members
        }
        if let input = asset.generationInput {
            if !input.prompt.isEmpty { payload["prompt"] = input.prompt }
            if !input.aspectRatio.isEmpty { payload["aspectRatio"] = input.aspectRatio }
            if let resolution = input.resolution, !resolution.isEmpty {
                payload["resolution"] = resolution
            }
            payload["model"] = ModelRegistry.displayName(for: input.model)
            if let iconKey = providerIconKey(for: input.model), !iconKey.isEmpty {
                payload["modelIconKey"] = iconKey
            }
            if let credits = CostEstimator.cost(for: input) {
                payload["credits"] = credits
            }
        }
        let duration = asset.resolvedDuration
        if (asset.type == .video || asset.type == .audio), duration > 0 {
            payload["duration"] = duration
        }

        switch asset.generationStatus {
        case .failed(let message):
            payload["status"] = "failed"
            payload["error"] = message
            return payload
        case .preparing:
            payload["status"] = "generating"
            payload["phase"] = "preparing"
            return payload
        case .generating:
            payload["status"] = "generating"
            payload["phase"] = "generating"
            return payload
        case .downloading:
            payload["status"] = "generating"
            payload["phase"] = "downloading"
            return payload
        case .rendering:
            payload["status"] = "generating"
            payload["phase"] = "rendering"
            return payload
        case .none:
            break
        }

        let url = asset.url
        let type = asset.type
        let encoded = await Task.detached(priority: .userInitiated) {
            await Self.encodeGenerationPreview(url: url, type: type, includeMedia: includeMedia)
        }.value
        payload["status"] = encoded.fileExists ? "ready" : "generating"
        if encoded.fileExists, asset.type == .video || asset.type == .audio {
            payload["mediaUrl"] = MCPPreviewApp.httpMediaURL(mediaRef: mediaRef)
            payload["mediaResourceUri"] = MCPPreviewApp.generationMediaURI(mediaRef: mediaRef)
            payload["mimeType"] = MCPPreviewApp.httpMediaMIMEType(url: url, type: type)
        }
        if let preview = encoded.preview {
            payload["preview"] = preview
        }
        if let audio = encoded.audio {
            payload["audio"] = audio
        }
        if let media = encoded.media {
            payload["media"] = media
        }
        return payload
    }

    private func providerIconKey(for modelId: String) -> String? {
        switch ModelRegistry.byId[modelId] {
        case .video(let model): model.entry.providerIconKey
        case .image(let model): model.entry.providerIconKey
        case .audio(let model): model.entry.providerIconKey
        case .upscale(let model): model.entry.providerIconKey
        case .none: nil
        }
    }

    private struct EncodedGenerationPreview: Sendable {
        var fileExists: Bool
        var preview: [String: String]?
        var audio: [String: String]?
        var media: [String: String]?
    }

    private nonisolated static func encodeGenerationPreview(
        url: URL,
        type: ClipType,
        includeMedia: Bool
    ) async -> EncodedGenerationPreview {
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard exists else {
            return EncodedGenerationPreview(fileExists: false, preview: nil, audio: nil, media: nil)
        }
        let media = includeMedia ? inlinePlayableMedia(url: url, type: type) : nil
        switch type {
        case .image:
            guard let image = ImageEncoder.thumbnail(url: url, maxPixelSize: MCPPreviewApp.previewMaxPixelSize),
                  let data = ImageEncoder.encodeJPEG(image, quality: 0.7)
            else {
                return EncodedGenerationPreview(fileExists: true, preview: nil, audio: nil, media: nil)
            }
            return EncodedGenerationPreview(
                fileExists: true,
                preview: ["mimeType": "image/jpeg", "data": data.base64EncodedString()],
                audio: nil,
                media: nil
            )
        case .video:
            if includeMedia {
                return EncodedGenerationPreview(fileExists: true, preview: nil, audio: nil, media: media)
            }
            guard let data = await videoPosterJPEG(url: url) else {
                return EncodedGenerationPreview(fileExists: true, preview: nil, audio: nil, media: nil)
            }
            return EncodedGenerationPreview(
                fileExists: true,
                preview: ["mimeType": "image/jpeg", "data": data.base64EncodedString()],
                audio: nil,
                media: nil
            )
        case .audio:
            if includeMedia {
                return EncodedGenerationPreview(fileExists: true, preview: nil, audio: nil, media: media)
            }
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = values.fileSize,
                  size > 0,
                  size <= MCPPreviewApp.maxAudioPreviewBytes,
                  let data = try? Data(contentsOf: url)
            else {
                return EncodedGenerationPreview(fileExists: true, preview: nil, audio: nil, media: nil)
            }
            return EncodedGenerationPreview(
                fileExists: true,
                preview: nil,
                audio: ["mimeType": audioMIMEType(url: url), "data": data.base64EncodedString()],
                media: nil
            )
        default:
            return EncodedGenerationPreview(fileExists: true, preview: nil, audio: nil, media: nil)
        }
    }

    private nonisolated static func inlinePlayableMedia(url: URL, type: ClipType) -> [String: String]? {
        guard type == .video || type == .audio else { return nil }
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > 0,
              size <= MCPPreviewApp.maxInlineMediaBytes,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return [
            "mimeType": MCPPreviewApp.httpMediaMIMEType(url: url, type: type),
            "data": data.base64EncodedString(),
        ]
    }

    private nonisolated static func videoPosterJPEG(url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: MCPPreviewApp.previewMaxPixelSize,
            height: MCPPreviewApp.previewMaxPixelSize
        )
        let time = CMTime(seconds: 0.1, preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: time).image else { return nil }
        return ImageEncoder.encodeJPEG(cgImage, quality: 0.7)
    }

    private nonisolated static func audioMIMEType(url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "m4a", "aac": "audio/mp4"
        case "ogg": "audio/ogg"
        case "flac": "audio/flac"
        default: "audio/mpeg"
        }
    }
}
