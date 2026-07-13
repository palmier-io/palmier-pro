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
        let prompt = try args.requireString("prompt")
        // Image generation routes to the OpenAI-compatible gateway when configured — no
        // hosted account/credits needed. Other types still use the hosted backend.
        let routesToGateway = (type == .image || type == .video) && OpenAICompatGenerationClient.gatewayConfigured
        if !routesToGateway {
            guard AccountService.shared.isSignedIn else {
                throw ToolError("Generation requires signing in to the hosted backend. Tell the user to sign in.")
            }
            guard AccountService.shared.hasCredits else {
                throw ToolError("Out of credits. Tell the user to add credits or subscribe to keep generating.")
            }
        }
        switch type {
        case .sequence:
            throw ToolError("Cannot generate a sequence. Sequences are timelines.")
        case .video:
            if OpenAICompatGenerationClient.gatewayConfigured {
                return try gatewayGenerateVideo(editor, args, prompt: prompt)
            }
            let modelId = try args.string("model") ?? defaultModelId(
                VideoModelConfig.allModels.map { (id: $0.id, paidOnly: $0.paidOnly) }, kind: "video")
            guard let model = VideoModelConfig.allModels.first(where: { $0.id == modelId }) else {
                throw ToolError("Unknown model '\(modelId)'. Available: \(VideoModelConfig.allModels.map(\.id).joined(separator: ", "))")
            }
            try requirePlan(for: model.id, paidOnly: model.paidOnly)
            return model.requiresSourceVideo
                ? try generateVideoEdit(editor, args, prompt: prompt, model: model)
                : try generateVideoText(editor, args, prompt: prompt, model: model)
        case .image:
            return try generateImage(editor, args, prompt: prompt)
        case .audio:
            throw ToolError("internal: audio generation is dispatched via the async path")
        case .text:
            throw ToolError("Text generation is not wired through the generate tool.")
        case .lottie:
            throw ToolError("Lottie animations aren't generated through this tool.")
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
            placeholderDuration: trimmed?.durationSeconds ?? (sourceAsset.duration > 0 ? sourceAsset.duration : 5),
            trimmedSourceOverride: trimmed,
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
        return .ok("Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), duration: \(duration)s, aspect: \(aspectRatio)\(refSummary)")
    }

    /// generate_video when the gateway is configured. Routes to an LTX bridge
    /// mode by the references given: none → text-to-video; a start frame → i2v;
    /// start + last frames → first-last-frame; a source video → extend.
    private func gatewayGenerateVideo(
        _ editor: EditorViewModel, _ args: [String: Any], prompt: String
    ) throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }
        let sourceRef = args.string("sourceVideoMediaRef")
        let startRef = args.string("startFrameMediaRef")
        let endRef = args.string("endFrameMediaRef")
        if sourceRef != nil, startRef != nil || endRef != nil {
            throw ToolError("Pick one: a source video to extend, or start/last frames to interpolate — not both.")
        }
        if endRef != nil, startRef == nil {
            throw ToolError("endFrameMediaRef needs a startFrameMediaRef — first-last-frame interpolates between two images.")
        }

        let duration = max(1, args.int("duration") ?? 5)
        var job = GatewayVideoJob(
            model: args.string("model") ?? GatewayVideoModels.resolve(GatewayVideoModels.gen),
            prompt: prompt,
            seconds: duration
        )
        job.size = GatewayGenerationRunner.videoSize(
            resolution: args.string("resolution"), aspectRatio: args.string("aspectRatio")
        )

        var fallbackRefs: [MediaAsset] = []
        var mode = "text-to-video"
        if let sourceRef {                                   // extend
            let source = try videoAsset(sourceRef, editor: editor, label: "Source video")
            job.inputReferenceURL = source.url
            fallbackRefs = [source]
            mode = "extend"
        } else if let startRef {                             // i2v or first-last-frame
            let start = try imageAsset(startRef, editor: editor, label: "Start frame")
            job.inputReferenceURL = start.url
            fallbackRefs = [start]
            mode = "image-to-video"
            if let endRef {
                let end = try imageAsset(endRef, editor: editor, label: "Last frame")
                job.lastFrameURL = end.url
                fallbackRefs.append(end)
                mode = "first-last-frame"
            }
        }

        let folderId = try resolveFolder(args, editor: editor, fallbackReferences: fallbackRefs)
        let placeholderId = editor.generationService.generateViaGateway(
            videoJob: job,
            name: args.string("name"),
            folderId: folderId,
            projectURL: editor.projectURL,
            editor: editor
        )
        return .ok("Generation started. Placeholder asset ID: \(placeholderId). Model: \(job.model), duration: \(duration)s (\(mode)). Poll get_media with this id; the result lands as a video asset.")
    }

    /// generate_audio when the gateway is configured: ACE-Step **music**
    /// generation (sync). TTS/voiceover and dubbing route to a different backend
    /// (Fish stack), so they're rejected by name here rather than silently
    /// falling through to the hosted sign-in guard.
    private func gatewayGenerateAudio(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let prompt = (args.string("prompt") ?? "").trimmingCharacters(in: .whitespaces)
        guard !prompt.isEmpty else {
            throw ToolError("The gateway audio model generates music from a prompt — describe the style, mood, or genre.")
        }
        if args.string("voice") != nil {
            throw ToolError("The gateway audio model is ACE-Step music generation, not TTS — omit `voice`. Speech routes to a separate backend.")
        }
        if args.string("sourceMediaRef") != nil || args.string("videoSourceMediaRef") != nil || args.string("targetLanguage") != nil {
            throw ToolError("Dubbing and source-media audio aren't on the gateway path yet — ACE-Step generates music from a text prompt.")
        }
        var job = GatewayAudioJob(
            model: args.string("model") ?? GatewayAudioModels.resolve(GatewayAudioModels.gen),
            prompt: prompt
        )
        job.lyrics = args.string("lyrics")
        let hasLyrics = !(job.lyrics?.isEmpty ?? true)
        job.instrumental = args.bool("instrumental") ?? !hasLyrics
        job.seconds = args.int("duration")
        job.seed = args.int("seed")
        if let format = args.string("format") { job.format = format }

        let folderId = try resolveFolder(args, editor: editor, fallbackReferences: [])
        let placeholderId = editor.generationService.generateViaGateway(
            audioJob: job,
            name: args.string("name"),
            folderId: folderId,
            projectURL: editor.projectURL,
            editor: editor
        )
        let kind = job.instrumental ? "instrumental" : (hasLyrics ? "song" : "music")
        let dur = job.seconds.map { "\($0)s " } ?? ""
        return .ok("Generation started. Placeholder asset ID: \(placeholderId). Model: \(job.model), \(dur)\(kind). Poll get_media with this id; the result lands as an audio asset.")
    }

    /// edit_audio: ACE-Step extend / repaint / lyric-edit on a source clip.
    func editAudioTool(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard OpenAICompatGenerationClient.gatewayConfigured else {
            throw ToolError("Audio tools need an OpenAI-compatible gateway. Tell the user to configure one in Settings → Agent.")
        }
        guard let op = GatewayAudioJob.Op(rawValue: (args.string("operation") ?? "").lowercased()), op != .generate else {
            throw ToolError("operation must be one of: extend, repaint, edit.")
        }
        let source = try audioAsset(try args.requireString("audioMediaRef"), editor: editor, label: "Source audio")
        let prompt = (args.string("prompt") ?? "").trimmingCharacters(in: .whitespaces)

        let model: String
        var fields: [String: String] = [:]
        switch op {
        case .extend:
            model = GatewayAudioModels.extendModel
            if let direction = args.string("direction") { fields["direction"] = direction }
        case .repaint:
            model = GatewayAudioModels.repaintModel
            guard let start = args.double("startSeconds"), let end = args.double("endSeconds"), end > start else {
                throw ToolError("repaint needs startSeconds and endSeconds (endSeconds > startSeconds).")
            }
            fields["start_s"] = Self.secondsField(start)
            fields["end_s"] = Self.secondsField(end)
            if let variance = args.double("variance") { fields["variance"] = Self.secondsField(variance) }
        case .edit:
            model = GatewayAudioModels.editModel
            guard !prompt.isEmpty || args.string("lyrics") != nil else {
                throw ToolError("edit needs a prompt or lyrics describing the new version.")
            }
            if let strength = args.double("editStrength") { fields["edit_strength"] = Self.secondsField(strength) }
        case .generate:
            throw ToolError("Use generate_audio for generation.")
        }

        var job = GatewayAudioJob(op: op, model: model, prompt: prompt)
        job.sourceAudioURL = source.url
        job.lyrics = args.string("lyrics")
        job.seconds = args.int("duration")
        job.seed = args.int("seed")
        if let format = args.string("format") { job.format = format }
        job.fields = fields

        let folderId = try resolveFolder(args, editor: editor, fallbackReferences: [source])
        let placeholderId = editor.generationService.generateViaGateway(
            audioJob: job, name: args.string("name"),
            folderId: folderId, projectURL: editor.projectURL, editor: editor
        )
        return .ok("\(op.rawValue.capitalized) started. Placeholder asset ID: \(placeholderId). Model: \(model), source: \(source.name). Poll get_media with this id; the result lands as an audio asset.")
    }

    private static func secondsField(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    private func audioAsset(_ id: String, editor: EditorViewModel, label: String) throws -> MediaAsset {
        let a = try asset(id, editor: editor, label: label)
        guard a.type == .audio else {
            throw ToolError("\(label) '\(id)' must be an audio asset (got \(a.type.rawValue)).")
        }
        guard FileManager.default.fileExists(atPath: a.url.path) else {
            throw ToolError("\(label) '\(id)' has no file on disk yet — it may still be generating. Poll get_media first.")
        }
        return a
    }

    private func imageAsset(_ id: String, editor: EditorViewModel, label: String) throws -> MediaAsset {
        let a = try asset(id, editor: editor, label: label)
        guard a.type == .image else {
            throw ToolError("\(label) '\(id)' must be an image asset (got \(a.type.rawValue)).")
        }
        guard FileManager.default.fileExists(atPath: a.url.path) else {
            throw ToolError("\(label) '\(id)' has no file on disk yet — it may still be generating. Poll get_media first.")
        }
        return a
    }

    private func videoAsset(_ id: String, editor: EditorViewModel, label: String) throws -> MediaAsset {
        let a = try asset(id, editor: editor, label: label)
        guard a.type == .video else {
            throw ToolError("\(label) '\(id)' must be a video asset (got \(a.type.rawValue)).")
        }
        guard FileManager.default.fileExists(atPath: a.url.path) else {
            throw ToolError("\(label) '\(id)' has no file on disk yet — it may still be generating. Poll get_media first.")
        }
        return a
    }

    private func generateImage(
        _ editor: EditorViewModel, _ args: [String: Any], prompt: String
    ) throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }
        if OpenAICompatGenerationClient.gatewayConfigured {
            return try gatewayGenerateImage(editor, args, prompt: prompt)
        }
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
        return .ok("Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), aspect: \(aspectRatio)")
    }

    func generateAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        if OpenAICompatGenerationClient.gatewayConfigured {
            return try gatewayGenerateAudio(editor, args)
        }
        guard AccountService.shared.isSignedIn else {
            throw ToolError("Generation requires signing in to the hosted backend. Tell the user to sign in.")
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
                ? args.string("targetLanguage") : nil
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
            targetLanguage: params.targetLanguage
        )
        if let sourceAsset {
            genInput.setAudioSourceAsset(sourceAsset)
        }

        let references = sourceAsset.map { [$0] } ?? []
        let folderId = try resolveFolder(args, editor: editor, fallbackReferences: references)
        let submission = AudioGenerationSubmission.make(
            genInput: genInput,
            model: model,
            params: params,
            name: args.string("name"),
            folderId: folderId,
            references: references
        )

        if let startFrame = placementStartFrame, let sourceSpan = spanSeconds {
            let outputSpan = requestedDurationSeconds.map(Double.init) ?? sourceSpan
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
            return .ok("Generation started and placed on the timeline at frame \(startFrame). Placeholder asset ID: \(placeholderId). Model: \(model.displayName), \(model.category.label) (scored from video).")
        }

        let placeholderId = submission.submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor
        )
        let sourceNote = sourceAsset != nil || videoURL != nil ? " (from source media)" : ""
        return .ok("Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), \(model.category.label)\(sourceNote). Place it with add_clips.")
    }

    func upscaleMedia(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .video || asset.type == .image else {
            throw ToolError("Upscale supports video and image assets only (got \(asset.type.rawValue))")
        }
        guard AccountService.shared.isSignedIn else {
            throw ToolError("Upscale requires signing in to the hosted backend. Tell the user to sign in.")
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
            model = match
        } else {
            guard let first = available.first(where: { modelAvailable(paidOnly: $0.paidOnly) }) else {
                throw ToolError("No upscaler available for \(asset.type.rawValue) on the current plan.")
            }
            model = first
        }

        let trimmed = try trimmedSource(args, editor: editor, source: asset)
        guard let placeholderId = EditSubmitter.submitUpscale(
            asset: asset, model: model, editor: editor, trimmedSource: trimmed
        ) else {
            throw ToolError("Failed to start upscale")
        }
        return .ok("Upscale started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), source: \(asset.name)\(trimmed != nil ? " (trimmed range)" : "")")
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

    func listModels(_ args: [String: Any]) async -> ToolResult {
        if OpenAICompatGenerationClient.gatewayConfigured,
           let client = OpenAICompatGenerationClient.fromGateway() {
            return await listGatewayModels(client: client, filter: args.string("type"))
        }
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

    private func listGatewayModels(
        client: OpenAICompatGenerationClient, filter: String?
    ) async -> ToolResult {
        let models: [OpenAICompatGenerationClient.GatewayModel]
        do {
            models = try await client.listModels()
        } catch {
            return .error("Could not list gateway models: \(error.localizedDescription)")
        }
        var out: [[String: Any]] = []
        for model in models {
            let type = Self.gatewayModelType(model.mode)
            if let filter, !filter.isEmpty, filter != type { continue }
            var info: [String: Any] = ["id": model.id, "type": type]
            if let mode = model.mode { info["mode"] = mode }
            out.append(info)
        }
        // The video and music models are served off-gateway (LTX bridge, ACE-Step
        // adapter), so they never appear in /v1/models — inject them so the agent
        // knows they exist.
        if filter == nil || filter?.isEmpty == true || filter == "video" {
            let videoId = GatewayVideoModels.resolve(GatewayVideoModels.gen)
            if !out.contains(where: { ($0["id"] as? String) == videoId }) {
                out.append(["id": videoId, "type": "video", "mode": "video_generation"])
            }
        }
        if filter == nil || filter?.isEmpty == true || filter == "audio" {
            let audioId = GatewayAudioModels.resolve(GatewayAudioModels.gen)
            if !out.contains(where: { ($0["id"] as? String) == audioId }) {
                out.append(["id": audioId, "type": "audio", "mode": "music_generation"])
            }
        }
        let body: [String: Any] = ["models": out, "loaded": true, "source": "gateway"]
        guard let json = Self.jsonString(body) else {
            return .error("Failed to encode model list")
        }
        return .ok(json)
    }

    /// Map a LiteLLM `model_info.mode` to the tool's type vocabulary.
    nonisolated static func gatewayModelType(_ mode: String?) -> String {
        guard let mode = mode?.lowercased() else { return "unknown" }
        if mode.contains("image") { return "image" }
        if mode.contains("video") { return "video" }
        if mode.contains("audio") || mode.contains("speech") || mode.contains("transcription") { return "audio" }
        if mode.contains("chat") || mode.contains("completion") { return "chat" }
        return mode
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
            "category": m.category.rawValue,
            "inputs": m.inputs.map(\.rawValue),
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
        [
            "id": m.id, "displayName": m.displayName,
            "type": "upscale",
            "speed": m.speed,
            "supportedTypes": m.supportedTypes.map(\.rawValue).sorted(),
        ]
    }
}
