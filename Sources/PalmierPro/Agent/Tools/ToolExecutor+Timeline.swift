import AVFoundation
import Foundation
import ImageIO

extension ToolExecutor {
    private static let defaultReadVideoFrames = 6
    private static let readVideoMaxFrames = 12
    private nonisolated static let readVideoFrameMaxDimension: CGFloat = 512
    private nonisolated static let readVideoJPEGQuality: CGFloat = 0.7
    private static let inspectMaxSegments = 250
    private static let inspectMaxWords = 500

    func getTimeline(_ editor: EditorViewModel) throws -> ToolResult {
        guard var dict = try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(editor.timeline)
        ) as? [String: Any] else { throw ToolError("Failed to encode timeline") }
        if var tracks = dict["tracks"] as? [[String: Any]] {
            for i in tracks.indices {
                if var clips = tracks[i]["clips"] as? [[String: Any]] {
                    for j in clips.indices {
                        clips[j] = Self.compactClipKeyframes(clips[j])
                    }
                    tracks[i]["clips"] = clips
                }
            }
            dict["tracks"] = tracks
        }
        dict["currentFrame"] = editor.currentFrame
        dict["canGenerate"] = AccountService.shared.isSignedIn && AccountService.shared.hasCredits
        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(dict, toPlaces: 3)) else {
            throw ToolError("Failed to encode timeline")
        }
        return .ok(json)
    }

    private static func compactClipKeyframes(_ clip: [String: Any]) -> [String: Any] {
        var out = clip
        var keyframes: [String: Any] = [:]
        for (trackKey, propKey, valueShape) in [
            ("volumeTrack", "volume", KeyframeValueShape.scalar),
            ("opacityTrack", "opacity", KeyframeValueShape.scalar),
            ("rotationTrack", "rotation", KeyframeValueShape.scalar),
            ("positionTrack", "position", KeyframeValueShape.pair),
            ("scaleTrack", "scale", KeyframeValueShape.pair),
            ("cropTrack", "crop", KeyframeValueShape.crop),
        ] {
            if let track = clip[trackKey] as? [String: Any],
               let kfs = track["keyframes"] as? [[String: Any]],
               !kfs.isEmpty {
                keyframes[propKey] = kfs.map { kf -> [Any] in
                    var row: [Any] = [kf["frame"] ?? 0]
                    row.append(contentsOf: valueShape.values(from: kf["value"]))
                    if let interp = kf["interpolationOut"] as? String, interp != "smooth" {
                        row.append(interp)
                    }
                    return row
                }
            }
            out.removeValue(forKey: trackKey)
        }
        if !keyframes.isEmpty { out["keyframes"] = keyframes }
        return out
    }

    private enum KeyframeValueShape {
        case scalar, pair, crop

        func values(from raw: Any?) -> [Any] {
            switch self {
            case .scalar:
                return [raw ?? 0]
            case .pair:
                guard let v = raw as? [String: Any] else { return [0, 0] }
                return [v["a"] ?? 0, v["b"] ?? 0]
            case .crop:
                guard let v = raw as? [String: Any] else { return [0, 0, 0, 0] }
                return [v["top"] ?? 0, v["right"] ?? 0, v["bottom"] ?? 0, v["left"] ?? 0]
            }
        }
    }

    func getMedia(_ editor: EditorViewModel) throws -> ToolResult {
        guard let obj = Self.encodeAsJSONObject(editor.mediaManifest),
              let json = Self.jsonString(roundJSONFloatingPointNumbers(obj, toPlaces: 3)) else {
            throw ToolError("Failed to encode media manifest")
        }
        return .ok(json)
    }

    private static let inspectMediaAllowedKeys: Set<String> = [
        "mediaRef", "clipId", "maxFrames", "startSeconds", "endSeconds", "wordTimestamps", "overview",
    ]

    func inspectMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.inspectMediaAllowedKeys, path: "inspect_media")
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        let url = asset.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            switch asset.generationStatus {
            case .downloading:
                throw ToolError("Asset \(asset.id) is still downloading. Poll get_media and retry once generationStatus becomes 'none'.")
            case .generating:
                throw ToolError("Asset \(asset.id) is still generating. Poll get_media and retry once generationStatus becomes 'none'.")
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

        switch asset.type {
        case .image: return try readImage(asset: asset, args: args)
        case .video: return try await readVideo(editor: editor, asset: asset, args: args, mapping: mapping)
        case .audio: return try await readAudio(editor: editor, asset: asset, args: args, mapping: mapping)
        case .text: throw ToolError("Text clips are not stored as media assets.")
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

    static func timelineMappingMeta(clip: Clip, fps: Int) -> [String: Any] {
        [
            "clipId": clip.id,
            "clipStartFrame": clip.startFrame,
            "clipEndFrame": clip.endFrame,
            "fps": fps,
            "note": "transcription segments/words are project frames for this clip; out-of-range entries are dropped.",
        ]
    }

    private func readImage(asset: MediaAsset, args: [String: Any]) throws -> ToolResult {
        let url = asset.url
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard let encoded = ImageEncoder.encode(url: url) else {
            throw ToolError("Failed to read or decode image file")
        }

        var meta = Self.baseMeta(for: asset)
        meta["mimeType"] = encoded.mime
        meta["byteSize"] = fileSize
        meta["encodedByteSize"] = encoded.data.count
        if let props = Self.imagePropertiesSummary(at: url) {
            meta["imageProperties"] = props
        }

        guard let metaJSON = Self.jsonString(roundJSONFloatingPointNumbers(meta, toPlaces: 3)) else {
            throw ToolError("Failed to encode metadata")
        }
        return ToolResult(
            content: [.image(base64: encoded.data.base64EncodedString(), mediaType: encoded.mime), .text(metaJSON)],
            isError: false
        )
    }

    private func readVideo(editor: EditorViewModel, asset: MediaAsset, args: [String: Any], mapping: (clip: Clip, fps: Int)? = nil) async throws -> ToolResult {
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
            do { return .success(try await TranscriptCache.shared.transcript(for: url, isVideo: true, range: range)) }
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

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
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

    private func readAudio(editor: EditorViewModel, asset: MediaAsset, args: [String: Any], mapping: (clip: Clip, fps: Int)? = nil) async throws -> ToolResult {
        let range = try Self.sourceRange(args, duration: asset.duration)
        let transcript: TranscriptionResult
        do {
            transcript = try await TranscriptCache.shared.transcript(for: asset.url, isVideo: false, range: range)
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

    private static func transcriptionMeta(
        from transcript: TranscriptionResult,
        mapping: (clip: Clip, fps: Int)? = nil,
        includeWords: Bool = false
    ) -> [String: Any] {
        var out: [String: Any] = [
            "timing": mapping == nil ? "sourceSeconds" : "projectFrames",
        ]
        if let lang = transcript.language { out["language"] = lang }

        let segments: [[Any]]
        if let mapping {
            segments = transcript.segments.compactMap { s in
                guard let f = spanFrames(start: s.start, end: s.end, clip: mapping.clip, fps: mapping.fps) else { return nil }
                return [s.text, f.start, f.end]
            }
        } else {
            segments = transcript.segments.map { [$0.text, round2OrNull($0.start), round2OrNull($0.end)] }
        }
        out["segments"] = Array(segments.prefix(inspectMaxSegments))
        if segments.count > inspectMaxSegments {
            out["totalSegments"] = segments.count
            out["segmentsNote"] = "First \(inspectMaxSegments) of \(segments.count) segments. Page through the rest with startSeconds/endSeconds."
        }

        if includeWords {
            let words: [[Any]]
            if let mapping {
                words = transcript.words.compactMap { w in
                    guard let start = w.start, let end = w.end,
                          let f = spanFrames(start: start, end: end, clip: mapping.clip, fps: mapping.fps) else { return nil }
                    return [w.text, f.start, f.end]
                }
            } else {
                words = transcript.words.map { [$0.text, round2OrNull($0.start), round2OrNull($0.end)] }
            }
            out["words"] = Array(words.prefix(inspectMaxWords))
            if words.count > inspectMaxWords {
                out["totalWords"] = words.count
                out["wordsNote"] = "First \(inspectMaxWords) of \(words.count) words. Narrow with startSeconds/endSeconds."
            }
        }
        return out
    }

    /// Maps a source-seconds span to the project frames it occupies on the clip
    private static func spanFrames(start: Double, end: Double, clip: Clip, fps: Int) -> (start: Int, end: Int)? {
        let visStart = Double(clip.trimStartFrame)
        let visEnd = visStart + Double(clip.durationFrames) * max(clip.speed, 0.0001)
        guard end * Double(fps) > visStart, start * Double(fps) < visEnd else { return nil }
        let s = clip.timelineFrame(sourceSeconds: start, fps: fps) ?? clip.startFrame
        let e = clip.timelineFrame(sourceSeconds: end, fps: fps) ?? clip.endFrame
        return (s, max(s, e))
    }

    private static func round2OrNull(_ x: Double?) -> Any {
        guard let x, x.isFinite else { return NSNull() }
        return NSDecimalNumber(string: String(format: "%.2f", x))
    }

    private static func baseMeta(for asset: MediaAsset) -> [String: Any] {
        var meta: [String: Any] = [
            "id": asset.id, "name": asset.name,
            "type": asset.type.rawValue, "duration": asset.duration.jsonRounded(toPlaces: 3),
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

    private static func generationStatusString(_ status: MediaAsset.GenerationStatus) -> String {
        switch status {
        case .none: "none"
        case .generating: "generating"
        case .downloading: "downloading"
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
