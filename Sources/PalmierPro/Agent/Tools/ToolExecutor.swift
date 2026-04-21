import AVFoundation
import Foundation
import ImageIO

/// Shared by the MCP server and the in-app agent.
@MainActor
final class ToolExecutor {

    private static let defaultReadImageMaxBytes = 20 * 1024 * 1024
    private static let defaultReadVideoFrames = 6
    private static let readVideoMaxFrames = 12
    private static let readVideoFrameMaxDimension: CGFloat = 512
    private static let readVideoJPEGQuality: CGFloat = 0.7

    weak var editor: EditorViewModel?

    init(editor: EditorViewModel) { self.editor = editor }

    func execute(name: String, args: [String: Any]) async -> ToolResult {
        guard let tool = ToolName(rawValue: name) else {
            return .error("Unknown tool: \(name)")
        }
        guard let editor else { return .error("Editor not available") }
        do {
            switch tool {
            case .getTimeline:   return try getTimeline(editor)
            case .getMedia:      return try getMedia(editor)
            case .readMedia:     return try await readMedia(editor, args)
            case .addTrack:      return try addTrack(editor, args)
            case .removeTrack:   return try removeTrack(editor, args)
            case .addClip:       return try addClip(editor, args)
            case .removeClip:    return try removeClip(editor, args)
            case .updateClip:    return try updateClip(editor, args)
            case .moveClip:      return try moveClip(editor, args)
            case .splitClip:     return try splitClip(editor, args)
            case .generateVideo: return try generate(editor, args, type: .video)
            case .generateImage: return try generate(editor, args, type: .image)
            case .generateAudio: return try generate(editor, args, type: .audio)
            case .upscaleMedia:  return try upscaleMedia(editor, args)
            case .listModels:    return listModels(args)
            }
        } catch let err as ToolError {
            return .error(err.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func getTimeline(_ editor: EditorViewModel) throws -> ToolResult {
        guard var dict = try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(editor.timeline)
        ) as? [String: Any] else { throw ToolError("Failed to encode timeline") }
        dict["currentFrame"] = editor.currentFrame
        dict["hasFalApiKey"] = editor.generationService.hasApiKey
        guard let json = Self.jsonString(dict) else { throw ToolError("Failed to encode timeline") }
        return .ok(json)
    }

    private func getMedia(_ editor: EditorViewModel) throws -> ToolResult {
        guard let data = try? JSONEncoder().encode(editor.mediaManifest),
              let json = String(data: data, encoding: .utf8) else {
            throw ToolError("Failed to encode media manifest")
        }
        return .ok(json)
    }

    private func readMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        let url = asset.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("Media file not on disk: \(url.lastPathComponent)")
        }
        switch asset.type {
        case .image: return try readImage(asset: asset, args: args)
        case .video: return try await readVideo(editor: editor, asset: asset, args: args)
        case .audio: return try await readAudio(editor: editor, asset: asset)
        }
    }

    private func readImage(asset: MediaAsset, args: [String: Any]) throws -> ToolResult {
        let url = asset.url
        let maxBytes = args.int("maxImageBytes") ?? Self.defaultReadImageMaxBytes
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize <= UInt64(maxBytes) else {
            throw ToolError("Image file (\(fileSize) bytes) exceeds maxImageBytes (\(maxBytes))")
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw ToolError("Failed to read image file")
        }

        let mime = Self.mimeTypeForImagePath(url.path)
        var meta = Self.baseMeta(for: asset)
        meta["mimeType"] = mime
        meta["byteSize"] = fileSize
        if let props = Self.imagePropertiesSummary(at: url) {
            meta["imageProperties"] = props
        }

        guard let metaJSON = Self.jsonString(meta) else { throw ToolError("Failed to encode metadata") }
        return ToolResult(
            content: [.image(base64: data.base64EncodedString(), mediaType: mime), .text(metaJSON)],
            isError: false
        )
    }

    private func readVideo(editor: EditorViewModel, asset: MediaAsset, args: [String: Any]) async throws -> ToolResult {
        guard asset.duration > 0 else { throw ToolError("Video has zero duration: \(asset.name)") }

        let requested = args.int("maxFrames") ?? Self.defaultReadVideoFrames
        let frameCount = max(1, min(requested, Self.readVideoMaxFrames))

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: Self.readVideoFrameMaxDimension,
            height: Self.readVideoFrameMaxDimension
        )
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        var frames: [(timestamp: Double, data: Data)] = []
        for i in 0..<frameCount {
            let t = asset.duration * (Double(i) + 0.5) / Double(frameCount)
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            guard let cgImage = try? await generator.image(at: cmTime).image else { continue }
            guard let jpeg = Self.jpegData(from: cgImage, quality: Self.readVideoJPEGQuality) else { continue }
            frames.append((timestamp: t, data: jpeg))
        }
        guard !frames.isEmpty else { throw ToolError("Failed to extract frames from \(asset.name)") }

        var meta = Self.baseMeta(for: asset)
        meta["hasAudio"] = asset.hasAudio
        meta["frameTimestamps"] = frames.map(\.timestamp)

        if asset.hasAudio {
            do {
                let transcript = try await editor.generationService.transcribeVideoAudio(videoURL: asset.url)
                meta["transcription"] = Self.transcriptionMeta(from: transcript)
            } catch {
                Log.generation.error("video transcription failed: \(error.localizedDescription)")
                meta["transcriptionError"] = error.localizedDescription
            }
        }

        guard let metaJSON = Self.jsonString(meta) else { throw ToolError("Failed to encode metadata") }

        var blocks: [ToolResult.Block] = frames.map {
            .image(base64: $0.data.base64EncodedString(), mediaType: "image/jpeg")
        }
        blocks.append(.text(metaJSON))
        return ToolResult(content: blocks, isError: false)
    }

    private func readAudio(editor: EditorViewModel, asset: MediaAsset) async throws -> ToolResult {
        guard editor.generationService.hasApiKey else {
            throw ToolError("No FAL API key configured — required for audio transcription. Set one in the app's generation panel.")
        }
        let transcript: GenerationService.TranscriptionResult
        do {
            transcript = try await editor.generationService.transcribe(fileURL: asset.url)
        } catch {
            throw ToolError("Transcription failed: \(error.localizedDescription)")
        }

        var meta = Self.baseMeta(for: asset)
        for (k, v) in Self.transcriptionMeta(from: transcript) { meta[k] = v }
        guard let metaJSON = Self.jsonString(meta) else { throw ToolError("Failed to encode metadata") }
        return .ok(metaJSON)
    }

    private static func transcriptionMeta(from transcript: GenerationService.TranscriptionResult) -> [String: Any] {
        var out: [String: Any] = [
            "text": transcript.text,
            "words": transcript.words.map { w -> [String: Any] in
                var entry: [String: Any] = ["text": w.text, "type": w.type]
                if let s = w.start { entry["start"] = s }
                if let e = w.end { entry["end"] = e }
                if let sid = w.speakerId { entry["speakerId"] = sid }
                return entry
            },
        ]
        if let lang = transcript.language { out["language"] = lang }
        if let p = transcript.languageProbability { out["languageProbability"] = p }
        return out
    }

    private static func baseMeta(for asset: MediaAsset) -> [String: Any] {
        var meta: [String: Any] = [
            "id": asset.id, "name": asset.name,
            "type": asset.type.rawValue, "duration": asset.duration,
            "fileName": asset.url.lastPathComponent,
            "generationStatus": generationStatusString(asset.generationStatus),
        ]
        if let w = asset.sourceWidth { meta["sourceWidth"] = w }
        if let h = asset.sourceHeight { meta["sourceHeight"] = h }
        if let fps = asset.sourceFPS { meta["sourceFPS"] = fps }
        if let gi = asset.generationInput, let obj = encodeAsJSONObject(gi) {
            meta["generationInput"] = obj
        }
        return meta
    }

    private static func encodeAsJSONObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value),
              let obj = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return obj
    }

    private static func jpegData(from cgImage: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.jpeg" as CFString, 1, nil
        ) else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private func addTrack(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let typeStr = try args.requireString("type")
        guard let type = ClipType(rawValue: typeStr) else {
            throw ToolError("Invalid 'type'. Must be: video, audio, image")
        }
        let label = args.string("label") ?? type.trackLabel
        let index = editor.insertTrack(at: editor.timeline.tracks.count, type: type, label: label)
        guard editor.timeline.tracks.indices.contains(index) else {
            throw ToolError("Failed to add track")
        }
        let track = editor.timeline.tracks[index]
        return .ok("Added track '\(label)' (type: \(typeStr), id: \(track.id)) at index \(index)")
    }

    private func removeTrack(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let trackId = try args.requireString("trackId")
        guard editor.timeline.tracks.contains(where: { $0.id == trackId }) else {
            throw ToolError("Track not found: \(trackId)")
        }
        editor.removeTrack(id: trackId)
        return .ok("Removed track \(trackId)")
    }

    private func addClip(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let mediaRef = try args.requireString("mediaRef")
        let trackIndex = try args.requireInt("trackIndex")
        let startFrame = try args.requireInt("startFrame")
        let durationFrames = try args.requireInt("durationFrames")

        guard editor.timeline.tracks.indices.contains(trackIndex) else {
            throw ToolError("Track index \(trackIndex) out of range (0..\(editor.timeline.tracks.count - 1))")
        }
        let asset = try asset(mediaRef, editor: editor)
        let targetType = editor.timeline.tracks[trackIndex].type
        guard asset.type.isCompatible(with: targetType) else {
            throw ToolError("Asset type \(asset.type.rawValue) is not compatible with \(targetType.rawValue) track at index \(trackIndex)")
        }

        let addedIds = editor.placeClip(
            asset: asset, trackIndex: trackIndex,
            startFrame: startFrame, durationFrames: durationFrames
        )
        editor.undoManager?.registerUndo(withTarget: editor) { vm in
            vm.removeClips(ids: Set(addedIds))
        }
        editor.undoManager?.setActionName("Add Clip (Agent)")
        editor.notifyTimelineChanged()

        let pairedNote = addedIds.count > 1 ? " (+linked audio clip \(addedIds[1]))" : ""
        return .ok("Added clip \(addedIds[0]) to track \(trackIndex) at frame \(startFrame)\(pairedNote)")
    }

    private func removeClip(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let clipId = try args.requireString("clipId")
        guard editor.findClip(id: clipId) != nil else { throw ToolError("Clip not found: \(clipId)") }
        let ids = editor.expandToLinkGroup([clipId])
        editor.removeClips(ids: ids)
        let extras = ids.count - 1
        let note = extras > 0 ? " (+\(extras) linked clip\(extras == 1 ? "" : "s"))" : ""
        return .ok("Removed clip \(clipId)\(note)")
    }

    private func updateClip(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let clipId = try args.requireString("clipId")
        guard let loc = editor.findClip(id: clipId) else { throw ToolError("Clip not found: \(clipId)") }
        editor.commitClipProperty(clipId: clipId) { clip in
            if let v = args.int("startFrame") { clip.startFrame = v }
            if let v = args.int("durationFrames") { clip.durationFrames = v }
            if let v = args.int("trimStartFrame") { clip.trimStartFrame = v }
            if let v = args.int("trimEndFrame") { clip.trimEndFrame = v }
            if let v = args.double("speed") { clip.speed = v }
            if let v = args.double("volume") { clip.volume = v }
            if let v = args.double("opacity") { clip.opacity = v }
        }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        return .ok("Updated clip \(clipId): startFrame=\(clip.startFrame), duration=\(clip.durationFrames)")
    }

    private func moveClip(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let clipId = try args.requireString("clipId")
        let toTrack = try args.requireInt("toTrack")
        let toFrame = try args.requireInt("toFrame")
        guard editor.findClip(id: clipId) != nil else { throw ToolError("Clip not found: \(clipId)") }
        guard editor.timeline.tracks.indices.contains(toTrack) else {
            throw ToolError("Track index \(toTrack) out of range (0..\(editor.timeline.tracks.count - 1))")
        }
        editor.moveClips([(clipId: clipId, toTrack: toTrack, toFrame: toFrame)])
        return .ok("Moved clip \(clipId) to track \(toTrack) at frame \(toFrame)")
    }

    private func splitClip(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let clipId = try args.requireString("clipId")
        let atFrame = try args.requireInt("atFrame")
        guard let loc = editor.findClip(id: clipId) else { throw ToolError("Clip not found: \(clipId)") }
        let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        guard atFrame > clip.startFrame && atFrame < clip.endFrame else {
            throw ToolError("Frame \(atFrame) is outside clip range (\(clip.startFrame)..\(clip.endFrame))")
        }
        let rightIds = editor.splitClip(clipId: clipId, atFrame: atFrame)
        let rightEndFrame = clip.endFrame
        let leftSummary = "\(clipId) (frames \(clip.startFrame)..\(atFrame))"
        let rightList = rightIds
            .map { "\($0) (frames \(atFrame)..\(rightEndFrame))" }
            .joined(separator: ", ")
        let rightNote = rightIds.isEmpty ? "" : " → new right clip(s): \(rightList)"
        return .ok("Split clip \(clipId) at frame \(atFrame). Left: \(leftSummary)\(rightNote)")
    }

    private func generate(_ editor: EditorViewModel, _ args: [String: Any], type: ClipType) throws -> ToolResult {
        let prompt = try args.requireString("prompt")
        guard editor.generationService.hasApiKey else {
            throw ToolError("No FAL API key configured. Set one in the app's generation panel first.")
        }
        switch type {
        case .video:
            let modelId = args.string("model") ?? VideoModelConfig.allModels[0].id
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
        guard sourceAsset.type == .video else {
            throw ToolError("sourceVideoMediaRef must reference a video asset")
        }

        var refs: [MediaAsset] = [sourceAsset]
        if model.supportsReferences, let imgRef = args.string("referenceImageMediaRef") {
            let imgAsset = try asset(imgRef, editor: editor, label: "Reference image")
            guard imgAsset.type == .image else {
                throw ToolError("referenceImageMediaRef must reference an image asset")
            }
            refs.append(imgAsset)
        }

        let genInput = GenerationInput(
            prompt: prompt, model: model.id, duration: Int(sourceAsset.duration.rounded()),
            aspectRatio: "", resolution: nil
        )
        let placeholderId = editor.generationService.generate(
            genInput: genInput, assetType: .video,
            placeholderDuration: sourceAsset.duration > 0 ? sourceAsset.duration : 5,
            references: refs, name: args.string("name"),
            buildInput: { uploaded in
                let params = VideoGenerationParams(
                    prompt: prompt, duration: 0, aspectRatio: "", resolution: nil,
                    sourceVideoURL: uploaded.first,
                    startFrameURL: nil, endFrameURL: nil,
                    referenceImageURLs: Array(uploaded.dropFirst()),
                    generateAudio: true
                )
                return (model.resolvedEndpoint(params: params), model.buildInput(params: params))
            },
            responseKeyPath: FalResponsePaths.video,
            fileExtension: "mp4",
            projectURL: editor.projectURL, editor: editor
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

        var frameRefs: [MediaAsset] = []
        if let startRef = args.string("startFrameMediaRef") {
            frameRefs.append(try asset(startRef, editor: editor, label: "Start frame"))
        }
        if let endRef = args.string("endFrameMediaRef") {
            frameRefs.append(try asset(endRef, editor: editor, label: "End frame"))
        }

        let genInput = GenerationInput(
            prompt: prompt, model: model.id, duration: duration,
            aspectRatio: aspectRatio, resolution: resolution
        )
        let placeholderId = editor.generationService.generate(
            genInput: genInput, assetType: .video,
            placeholderDuration: Double(max(1, duration)),
            references: frameRefs, name: args.string("name"),
            buildInput: { uploaded in
                let params = VideoGenerationParams(
                    prompt: prompt, duration: duration,
                    aspectRatio: aspectRatio, resolution: resolution,
                    sourceVideoURL: nil,
                    startFrameURL: uploaded.first,
                    endFrameURL: uploaded.count > 1 ? uploaded[1] : nil,
                    referenceImageURLs: [], generateAudio: true
                )
                return (model.resolvedEndpoint(params: params), model.buildInput(params: params))
            },
            responseKeyPath: FalResponsePaths.video,
            fileExtension: "mp4",
            projectURL: editor.projectURL, editor: editor
        )
        return .ok("Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), duration: \(duration)s, aspect: \(aspectRatio)")
    }

    private func generateImage(
        _ editor: EditorViewModel, _ args: [String: Any], prompt: String
    ) throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }
        let modelId = args.string("model") ?? ImageModelConfig.allModels[0].id
        guard let model = ImageModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(ImageModelConfig.allModels.map(\.id).joined(separator: ", "))")
        }
        let aspectRatio = args.string("aspectRatio") ?? model.aspectRatios[0]
        let resolution = args.string("resolution") ?? model.resolutions?.first
        let quality = args.string("quality") ?? model.qualities?.last
        let refs: [MediaAsset] = args.stringArray("referenceMediaRefs").compactMap { id in
            editor.mediaAssets.first(where: { $0.id == id })
        }

        let genInput = GenerationInput(
            prompt: prompt, model: modelId, duration: 0,
            aspectRatio: aspectRatio, resolution: resolution, quality: quality
        )
        let placeholderId = editor.generationService.generate(
            genInput: genInput, assetType: .image,
            placeholderDuration: Defaults.imageDurationSeconds,
            references: refs, name: args.string("name"),
            buildInput: { uploaded in
                let input = model.buildInput(
                    prompt: prompt, aspectRatio: aspectRatio,
                    resolution: resolution, quality: quality, imageURLs: uploaded
                )
                return (model.resolvedEndpoint(imageURLs: uploaded), input)
            },
            responseKeyPath: FalResponsePaths.generatedImage,
            fileExtension: "jpg",
            projectURL: editor.projectURL, editor: editor
        )
        return .ok("Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), aspect: \(aspectRatio)")
    }

    private func generateAudio(
        _ editor: EditorViewModel, _ args: [String: Any], prompt: String
    ) throws -> ToolResult {
        let modelId = args.string("model") ?? AudioModelConfig.allModels[0].id
        guard let model = AudioModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(AudioModelConfig.allModels.map(\.id).joined(separator: ", "))")
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= model.minPromptLength else {
            throw ToolError("Model '\(model.id)' requires prompt ≥ \(model.minPromptLength) chars (got \(trimmed.count))")
        }
        if let voice = args.string("voice"),
           let voices = model.voices,
           !voices.contains(voice) {
            throw ToolError("Voice '\(voice)' not supported by \(model.id). Available: \(voices.joined(separator: ", "))")
        }

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

        let placeholderDuration: Double = {
            if let secs = params.durationSeconds { return Double(secs) }
            return model.category == .music
                ? Defaults.audioMusicDurationSeconds
                : Defaults.audioTTSDurationSeconds
        }()

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

        let placeholderId = editor.generationService.generate(
            genInput: genInput, assetType: .audio,
            placeholderDuration: placeholderDuration,
            name: args.string("name"),
            buildInput: { _ in
                (model.baseEndpoint, model.buildInput(params: params))
            },
            responseKeyPath: FalResponsePaths.audio,
            fileExtension: "mp3",
            projectURL: editor.projectURL, editor: editor
        )
        return .ok("Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), category: \(model.category == .music ? "music" : "tts")")
    }

    private func upscaleMedia(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .video || asset.type == .image else {
            throw ToolError("Upscale supports video and image assets only (got \(asset.type.rawValue))")
        }
        guard editor.generationService.hasApiKey else {
            throw ToolError("No FAL API key configured. Set one in the app's generation panel first.")
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
            asset: asset, model: model, editor: editor, service: editor.generationService
        ) else {
            throw ToolError("Failed to start upscale")
        }
        return .ok("Upscale started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), source: \(asset.name)")
    }

    private func listModels(_ args: [String: Any]) -> ToolResult {
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
        guard let json = Self.jsonString(out) else { return .error("Failed to encode model list") }
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
        if m.maxReferences > 0 { info["maxReferences"] = m.maxReferences }
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

    nonisolated static func jsonString(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func asset(_ id: String, editor: EditorViewModel, label: String = "Media asset") throws -> MediaAsset {
        guard let asset = editor.mediaAssets.first(where: { $0.id == id }) else {
            throw ToolError("\(label) not found: \(id)")
        }
        return asset
    }

    private static func mimeTypeForImagePath(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "gif": "image/gif"
        case "tiff", "tif": "image/tiff"
        case "heic", "heif": "image/heic"
        case "webp": "image/webp"
        default: "application/octet-stream"
        }
    }

    private static func generationStatusString(_ status: MediaAsset.GenerationStatus) -> String {
        switch status {
        case .none: "none"
        case .generating: "generating"
        case .failed(let message): "failed: \(message)"
        }
    }

    private static func imagePropertiesSummary(at url: URL) -> [String: Any]? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        var out: [String: Any] = [:]
        if let v = props[kCGImagePropertyPixelWidth] { out["pixelWidth"] = v }
        if let v = props[kCGImagePropertyPixelHeight] { out["pixelHeight"] = v }
        if let v = props[kCGImagePropertyOrientation] { out["orientation"] = v }
        if let v = props[kCGImagePropertyDepth] { out["depth"] = v }
        if let v = props[kCGImagePropertyColorModel] { out["colorModel"] = v }
        return out.isEmpty ? nil : out
    }
}

struct ToolError: Error { let message: String; init(_ m: String) { self.message = m } }

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let v = self[key] as? String, !v.isEmpty { return v }
        return nil
    }
    func int(_ key: String) -> Int? {
        if let v = self[key] as? Int { return v }
        if let v = self[key] as? Double { return Int(v) }
        if let v = self[key] as? NSNumber { return v.intValue }
        if let v = self[key] as? String { return Int(v) }
        return nil
    }
    func double(_ key: String) -> Double? {
        if let v = self[key] as? Double { return v }
        if let v = self[key] as? Int { return Double(v) }
        if let v = self[key] as? NSNumber { return v.doubleValue }
        if let v = self[key] as? String { return Double(v) }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        if let v = self[key] as? Bool { return v }
        if let v = self[key] as? NSNumber { return v.boolValue }
        if let v = self[key] as? String { return Bool(v) }
        return nil
    }
    func stringArray(_ key: String) -> [String] {
        (self[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }
    func requireString(_ key: String) throws -> String {
        guard let v = self[key] as? String else { throw ToolError("Missing required argument: \(key)") }
        return v
    }
    func requireInt(_ key: String) throws -> Int {
        guard let v = int(key) else { throw ToolError("Missing required argument: \(key)") }
        return v
    }
    func requireDouble(_ key: String) throws -> Double {
        guard let v = double(key) else { throw ToolError("Missing required argument: \(key)") }
        return v
    }
}
