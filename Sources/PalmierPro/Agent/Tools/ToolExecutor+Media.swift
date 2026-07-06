import AVFoundation
import Foundation
import ImageIO

// get_media (library inventory) and inspect_media (frames, EXIF, transcription per asset).
extension ToolExecutor {
    private static let getMediaAllowedKeys: Set<String> = ["ids", "folder", "pending"]
    private static let getMediaPromptLimit = 100

    private static let inspectMediaAllowedKeys: Set<String> = [
        "mediaRef", "clipId", "maxFrames", "startSeconds", "endSeconds", "wordTimestamps", "overview", "language",
    ]
    private static let defaultReadVideoFrames = 6
    private static let readVideoMaxFrames = 12
    private nonisolated static let readVideoFrameMaxDimension: CGFloat = 512
    private nonisolated static let readVideoJPEGQuality: CGFloat = 0.7

    // MARK: - get_media

    func getMedia(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.getMediaAllowedKeys, path: "get_media")
        let idFilter = Set(args.stringArray("ids"))
        let pendingOnly = args["pending"] as? Bool ?? false
        var folderScope: Set<String>?
        if let folderPath = args.string("folder") {
            folderScope = editor.folderIdsIncludingDescendants(
                [try folderId(atPath: folderPath, editor: editor)])
        }

        var assets: [[String: Any]] = []
        for entry in editor.mediaManifest.entries {
            if !idFilter.isEmpty && !idFilter.contains(entry.id) { continue }
            let status = entry.generationStatus
            let pending = status != nil && status != "none"
            if pendingOnly && !pending { continue }
            if let folderScope {
                guard let f = entry.folderId, folderScope.contains(f) else { continue }
            }
            var a: [String: Any] = ["id": entry.id, "name": entry.name, "type": entry.type.rawValue]
            if entry.duration > 0 { a["durationSeconds"] = entry.duration }
            if let w = entry.sourceWidth, let h = entry.sourceHeight { a["width"] = w; a["height"] = h }
            if let fps = entry.sourceFPS { a["fps"] = fps }
            if entry.hasAudio == true, entry.type == .video { a["hasAudio"] = true }
            if let path = folderPathString(entry.folderId, editor: editor) { a["folder"] = path }
            if pending, let status { a["generationStatus"] = status }
            if let prompt = Self.truncatedPrompt(entry.generationInput?.prompt) { a["prompt"] = prompt }
            assets.append(a)
        }

        var payload: [String: Any] = ["assets": assets]
        // Full inventory only on unfiltered reads; filtered reads (polling) stay minimal.
        if idFilter.isEmpty && !pendingOnly && folderScope == nil {
            let folderPaths = allFolderPaths(editor)
            if !folderPaths.isEmpty { payload["folders"] = folderPaths }
            payload["timelines"] = timelineEntries(editor, detailed: true)
        }
        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) else {
            throw ToolError("Failed to encode media library")
        }
        return .ok(json)
    }

    // MARK: - inspect_media

    func inspectMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.inspectMediaAllowedKeys, path: "inspect_media")
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        let url = asset.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            switch asset.generationStatus {
            case .preparing:
                throw ToolError("Asset \(asset.id) is still preparing. Poll get_media and retry once generationStatus becomes 'none'.")
            case .downloading:
                throw ToolError("Asset \(asset.id) is still downloading. Poll get_media and retry once generationStatus becomes 'none'.")
            case .generating:
                throw ToolError("Asset \(asset.id) is still generating. Poll get_media and retry once generationStatus becomes 'none'.")
            case .rendering:
                throw ToolError("Asset \(asset.id) is still rendering. Poll get_media and retry once generationStatus becomes 'none'.")
            case .failed(let msg):
                throw ToolError("Asset \(asset.id) failed: \(msg)")
            case .none:
                throw ToolError("Media file not on disk: \(url.lastPathComponent)")
            }
        }

        var mapping: (clip: Clip, fps: Int)?
        if let clipId = args.string("clipId") {
            guard let loc = editor.findClip(id: clipId) else {
                throw ToolError("Clip not found: \(clipId)")
            }
            let clip = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
            guard clip.mediaRef == mediaRef else {
                throw ToolError("Clip \(clipId) does not reference mediaRef \(mediaRef) (it references \(clip.mediaRef))")
            }
            mapping = (clip, editor.timeline.fps)
        }

        let preferredLocale = try await Self.parseLocale(args, path: "inspect_media")

        switch asset.type {
        case .image: return try await readImage(asset: asset, args: args)
        case .video: return try await readVideo(editor: editor, asset: asset, args: args, mapping: mapping, preferredLocale: preferredLocale)
        case .audio: return try await readAudio(editor: editor, asset: asset, args: args, mapping: mapping, preferredLocale: preferredLocale)
        case .lottie: return try await readLottie(asset: asset, args: args)
        case .text: throw ToolError("Text clips are not stored as media assets.")
        case .sequence: throw ToolError("Sequences are timelines, not media assets. Use get_timeline.")
        }
    }

    private static func sourceRange(_ args: [String: Any], duration: Double) throws -> ClosedRange<Double>? {
        let start = args.double("startSeconds")
        let end = args.double("endSeconds")
        guard start != nil || end != nil else { return nil }
        let s = max(start ?? 0, 0)
        let e = min(end ?? duration, duration)
        guard s < e else {
            throw ToolError("Invalid time range [\(s), \(e)] for media of duration \(duration)s")
        }
        return s...e
    }

    private func readImage(asset: MediaAsset, args: [String: Any]) async throws -> ToolResult {
        let url = asset.url
        let encoded = await Task.detached(priority: .userInitiated) {
            ImageEncoder.encode(url: url).map {
                (base64: $0.data.base64EncodedString(), mime: $0.mime, encodedByteSize: $0.data.count)
            }
        }.value
        guard let encoded else {
            throw ToolError("Failed to read or decode image file")
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        var meta = Self.baseMeta(for: asset)
        meta["mimeType"] = encoded.mime
        meta["byteSize"] = fileSize
        meta["encodedByteSize"] = encoded.encodedByteSize
        if let props = Self.imagePropertiesSummary(at: url) {
            meta["imageProperties"] = props
        }

        guard let metaJSON = Self.jsonString(roundJSONFloatingPointNumbers(meta, toPlaces: 3)) else {
            throw ToolError("Failed to encode metadata")
        }
        return ToolResult(
            content: [.image(base64: encoded.base64, mediaType: encoded.mime), .text(metaJSON)],
            isError: false
        )
    }

    private func readVideo(editor: EditorViewModel, asset: MediaAsset, args: [String: Any], mapping: (clip: Clip, fps: Int)? = nil, preferredLocale: Locale? = nil) async throws -> ToolResult {
        guard asset.duration > 0 else { throw ToolError("Video has zero duration: \(asset.name)") }

        let range = try Self.sourceRange(args, duration: asset.duration)
        let windowStart = range?.lowerBound ?? 0
        let windowEnd = range?.upperBound ?? asset.duration

        var meta = Self.baseMeta(for: asset)
        meta["hasAudio"] = asset.hasAudio
        if let range { meta["timeRange"] = [range.lowerBound, range.upperBound] }

        // Frames/overview and transcription touch independent subsystems — run them concurrently
        let url = asset.url
        let hasAudio = asset.hasAudio
        let wantsOverview = args.bool("overview") == true
        let requested = args.int("maxFrames") ?? Self.defaultReadVideoFrames
        let frameCount = max(1, min(requested, Self.readVideoMaxFrames))
        async let visualTask = Self.extractVisual(
            url: url, name: asset.name, overview: wantsOverview,
            frameCount: frameCount, start: windowStart, end: windowEnd
        )
        async let transcriptTask: Result<TranscriptionResult, Error>? = {
            guard hasAudio else { return nil }
            do { return .success(try await TranscriptCache.shared.transcript(for: url, isVideo: true, range: range, preferredLocale: preferredLocale)) }
            catch { return .failure(error) }
        }()

        var imageBlocks: [ToolResult.Block] = []
        switch try await visualTask {
        case .overview(let jpeg, let timestamps):
            meta["overview"] = ["tileTimestamps": timestamps.map { $0.jsonRounded(toPlaces: 3) }]
            imageBlocks = [.image(base64: jpeg.base64EncodedString(), mediaType: "image/jpeg")]
        case .frames(let frames):
            meta["frameTimestamps"] = frames.map { $0.timestamp.jsonRounded(toPlaces: 3) }
            imageBlocks = frames.map { .image(base64: $0.jpeg.base64EncodedString(), mediaType: "image/jpeg") }
        }

        switch await transcriptTask {
        case .success(let transcript):
            meta["transcription"] = Self.transcriptionMeta(
                from: transcript, mapping: mapping, includeWords: args.bool("wordTimestamps") ?? false
            )
        case .failure(let error):
            Log.transcription.error("video transcription failed: \(error.localizedDescription)")
            meta["transcriptionError"] = error.localizedDescription
        case nil:
            break
        }
        if let mapping { meta["timelineMapping"] = Self.timelineMappingMeta(clip: mapping.clip, fps: mapping.fps) }

        guard let metaJSON = Self.jsonString(roundJSONFloatingPointNumbers(meta, toPlaces: 3)) else {
            throw ToolError("Failed to encode metadata")
        }
        return ToolResult(content: imageBlocks + [.text(metaJSON)], isError: false)
    }

    private enum Visual: Sendable {
        case frames([(timestamp: Double, jpeg: Data)])
        case overview(jpeg: Data, timestamps: [Double])
    }

    private nonisolated static func extractVisual(
        url: URL, name: String, overview: Bool, frameCount: Int, start: Double, end: Double
    ) async throws -> Visual {
        if overview {
            do {
                let sheet = try await OverviewRenderer.make(url: url, start: start, end: end)
                return .overview(jpeg: sheet.jpeg, timestamps: sheet.timestamps)
            } catch {
                throw ToolError("Overview failed: \(error.localizedDescription)")
            }
        }

        let asset = AVURLAsset(url: url)
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else {
            throw ToolError("No video track available in \(name)")
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: readVideoFrameMaxDimension,
            height: readVideoFrameMaxDimension
        )
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.25, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.25, preferredTimescale: 600)

        var frames: [(timestamp: Double, jpeg: Data)] = []
        for i in 0..<frameCount {
            let t = start + (end - start) * (Double(i) + 0.5) / Double(frameCount)
            let cmTime = CMTime(seconds: t, preferredTimescale: 600)
            guard let cgImage = try? await generator.image(at: cmTime).image else { continue }
            guard let jpeg = ImageEncoder.encodeJPEG(cgImage, quality: readVideoJPEGQuality) else { continue }
            frames.append((timestamp: t, jpeg: jpeg))
        }
        guard !frames.isEmpty else { throw ToolError("Failed to extract frames from \(name)") }
        return .frames(frames)
    }

    private func readLottie(asset: MediaAsset, args: [String: Any]) async throws -> ToolResult {
        let count = max(1, min(args.int("maxFrames") ?? Self.defaultReadVideoFrames, Self.readVideoMaxFrames))
        let (lottieMeta, frames) = try await LottieVideoGenerator.sampleFrames(fileAt: asset.url, count: count)
        guard !frames.isEmpty else { throw ToolError("Failed to render Lottie frames from \(asset.name)") }

        var meta = Self.baseMeta(for: asset)
        meta["framerate"] = lottieMeta.framerate
        meta["frameCount"] = lottieMeta.frameCount
        meta["durationSeconds"] = lottieMeta.duration
        meta["sampledFrameIndices"] = frames.map(\.frameIndex)
        meta["note"] = "Lottie frames sampled evenly across the animation; transparent areas composited over gray."

        let imageBlocks: [ToolResult.Block] = frames.compactMap { frame in
            Self.compositeJPEG(frame.image).map { .image(base64: $0.base64EncodedString(), mediaType: "image/jpeg") }
        }
        guard !imageBlocks.isEmpty else { throw ToolError("Failed to encode Lottie frames") }
        guard let metaJSON = Self.jsonString(roundJSONFloatingPointNumbers(meta, toPlaces: 3)) else {
            throw ToolError("Failed to encode metadata")
        }
        return ToolResult(content: imageBlocks + [.text(metaJSON)], isError: false)
    }

    /// Composites an alpha frame over mid-gray so transparent regions read clearly to the model.
    private static func compositeJPEG(_ image: CGImage, quality: CGFloat = 0.7) -> Data? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(rect)
        context.draw(image, in: rect)
        return context.makeImage().flatMap { ImageEncoder.encodeJPEG($0, quality: quality) }
    }

    private func readAudio(editor: EditorViewModel, asset: MediaAsset, args: [String: Any], mapping: (clip: Clip, fps: Int)? = nil, preferredLocale: Locale? = nil) async throws -> ToolResult {
        let range = try Self.sourceRange(args, duration: asset.duration)
        let transcript: TranscriptionResult
        do {
            transcript = try await TranscriptCache.shared.transcript(for: asset.url, isVideo: false, range: range, preferredLocale: preferredLocale)
        } catch {
            throw ToolError("Transcription failed: \(error.localizedDescription)")
        }

        var meta = Self.baseMeta(for: asset)
        if let range { meta["timeRange"] = [range.lowerBound, range.upperBound] }
        let transcription = Self.transcriptionMeta(
            from: transcript, mapping: mapping, includeWords: args.bool("wordTimestamps") ?? false
        )
        for (k, v) in transcription { meta[k] = v }
        if let mapping { meta["timelineMapping"] = Self.timelineMappingMeta(clip: mapping.clip, fps: mapping.fps) }
        guard let metaJSON = Self.jsonString(roundJSONFloatingPointNumbers(meta, toPlaces: 3)) else {
            throw ToolError("Failed to encode metadata")
        }
        return .ok(metaJSON)
    }

    /// Same vocabulary as get_media assets, so one asset never describes itself two ways.
    private static func baseMeta(for asset: MediaAsset) -> [String: Any] {
        var meta: [String: Any] = [
            "id": asset.id, "name": asset.name,
            "type": asset.type.rawValue,
            "durationSeconds": asset.duration.jsonRounded(toPlaces: 3),
            "fileName": asset.url.lastPathComponent,
        ]
        if case .none = asset.generationStatus {} else {
            meta["generationStatus"] = asset.generationStatus.serialized
        }
        if let w = asset.sourceWidth { meta["width"] = w }
        if let h = asset.sourceHeight { meta["height"] = h }
        if let fps = asset.sourceFPS { meta["fps"] = fps }
        if let prompt = truncatedPrompt(asset.generationInput?.prompt) { meta["prompt"] = prompt }
        return meta
    }

    private static func truncatedPrompt(_ prompt: String?) -> String? {
        guard let prompt, !prompt.isEmpty else { return nil }
        return prompt.count > getMediaPromptLimit ? String(prompt.prefix(getMediaPromptLimit)) + "…" : prompt
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
