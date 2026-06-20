import AVFoundation
import Foundation
import ImageIO

extension ToolExecutor {
    private static let defaultReadVideoFrames = 6
    private static let readVideoMaxFrames = 12
    private nonisolated static let readVideoFrameMaxDimension: CGFloat = 512
    private nonisolated static let readVideoJPEGQuality: CGFloat = 0.7
    private static let inspectMaxSegments = 400
    private static let inspectMaxWords = 10000

    private static let getTimelineAllowedKeys: Set<String> = ["startFrame", "endFrame"]
    private static let captionRowLimit = 200
    private static let captionRowFormat = ["clipId", "startFrame", "durationFrames", "text"]

    func getTimeline(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.getTimelineAllowedKeys, path: "get_timeline")
        var window: Range<Int>?
        if args.int("startFrame") != nil || args.int("endFrame") != nil {
            let s = args.int("startFrame") ?? 0
            let e = args.int("endFrame") ?? Int.max
            guard s < e else {
                throw ToolError("Invalid window [\(s), \(e)): startFrame must be less than endFrame")
            }
            window = s..<e
        }

        guard var dict = try? JSONSerialization.jsonObject(
            with: JSONEncoder().encode(editor.timeline)
        ) as? [String: Any] else { throw ToolError("Failed to encode timeline") }
        if var tracks = dict["tracks"] as? [[String: Any]] {
            for i in tracks.indices {
                tracks[i] = Self.compactTrack(tracks[i], window: window)
                // Report the displayed label (mirrored video numbering), not the stored seed.
                tracks[i]["label"] = editor.timelineTrackDisplayLabel(at: i)
            }
            dict["tracks"] = tracks
        }
        dict["totalFrames"] = editor.timeline.totalFrames
        if let window {
            dict["window"] = [window.lowerBound, min(window.upperBound, editor.timeline.totalFrames)]
        }
        dict["currentFrame"] = editor.currentFrame
        dict["canGenerate"] = AccountService.shared.isSignedIn && AccountService.shared.hasCredits
        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(dict, toPlaces: 3)) else {
            throw ToolError("Failed to encode timeline")
        }
        return .ok(json)
    }

    private static let trackDefaults: [String: Any] = ["muted": false, "hidden": false, "syncLocked": true]

    private static let clipDefaults: [String: Any] = {
        var clip = Clip(mediaRef: "", startFrame: 0, durationFrames: 0)
        clip.textStyle = TextStyle()
        guard let data = try? JSONEncoder().encode(clip),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        // Identity fields stay; sourceClipType strips only when it matches mediaType.
        for key in ["id", "mediaRef", "startFrame", "durationFrames", "sourceClipType"] {
            obj.removeValue(forKey: key)
        }
        return obj
    }()

    private static func compactTrack(_ track: [String: Any], window: Range<Int>?) -> [String: Any] {
        var out = strippingDefaults(track, trackDefaults)
        guard let rawClips = track["clips"] as? [[String: Any]] else { return out }
        let compacted = rawClips.map { compactClip($0) }

        var loose: [[String: Any]] = []
        var groupOrder: [String] = []
        var grouped: [String: [[String: Any]]] = [:]
        for clip in compacted {
            if let gid = clip["captionGroupId"] as? String {
                if grouped[gid] == nil { groupOrder.append(gid) }
                grouped[gid, default: []].append(clip)
            } else {
                loose.append(clip)
            }
        }

        var groups: [[String: Any]] = []
        for gid in groupOrder {
            let (group, deviants) = captionGroup(gid: gid, members: grouped[gid] ?? [], window: window)
            groups.append(group)
            loose.append(contentsOf: deviants)
        }
        loose.sort { intValue($0["startFrame"]) < intValue($1["startFrame"]) }

        let visible = window.map { w in loose.filter { clipIntersects($0, w) } } ?? loose
        out["clips"] = visible
        if visible.count < loose.count { out["totalClips"] = loose.count }
        if !groups.isEmpty { out["captionGroups"] = groups }
        return out
    }

    private static func compactClip(_ clip: [String: Any]) -> [String: Any] {
        var out = compactClipKeyframes(clip)
        if let s = out["sourceClipType"] as? String, s == out["mediaType"] as? String {
            out.removeValue(forKey: "sourceClipType")
        }
        // Text has no source media; trims are placement bookkeeping, not signal.
        if out["mediaType"] as? String == "text" {
            out.removeValue(forKey: "trimStartFrame")
            out.removeValue(forKey: "trimEndFrame")
        }
        return strippingDefaults(out, clipDefaults)
    }

    /// Removes keys whose values equal the defaults; recurses into nested objects.
    private static func strippingDefaults(_ dict: [String: Any], _ defaults: [String: Any]) -> [String: Any] {
        var out = dict
        for (key, def) in defaults {
            guard let val = out[key] else { continue }
            if let v = val as? [String: Any], let d = def as? [String: Any] {
                let stripped = strippingDefaults(v, d)
                if stripped.isEmpty { out.removeValue(forKey: key) } else { out[key] = stripped }
            } else if (val as? NSObject)?.isEqual(def) == true {
                out.removeValue(forKey: key)
            }
        }
        return out
    }

    /// Collapses one caption group into shared properties + compact rows.
    private static func captionGroup(
        gid: String, members: [[String: Any]], window: Range<Int>?
    ) -> (group: [String: Any], deviants: [[String: Any]]) {
        let rowKeys: Set<String> = ["id", "startFrame", "durationFrames", "textContent", "captionGroupId"]
        var counts: [String: Int] = [:]
        var modalKey = ""
        var shared: [String: Any] = [:]
        let entries: [(clip: [String: Any], key: String)] = members.map { clip in
            var residual = clip.filter { !rowKeys.contains($0.key) }
            // Caption boxes are auto-fit per text; size is derived data, not signal.
            if var t = residual["transform"] as? [String: Any] {
                t.removeValue(forKey: "width")
                t.removeValue(forKey: "height")
                if t.isEmpty { residual.removeValue(forKey: "transform") } else { residual["transform"] = t }
            }
            let key = canonicalJSON(residual)
            counts[key, default: 0] += 1
            if counts[key]! > counts[modalKey, default: 0] {
                modalKey = key
                shared = residual
            }
            return (clip, key)
        }

        var rows: [[Any]] = []
        var deviants: [[String: Any]] = []
        var frameMin = Int.max
        var frameMax = 0
        for (clip, key) in entries {
            let start = intValue(clip["startFrame"])
            let end = start + intValue(clip["durationFrames"])
            frameMin = min(frameMin, start)
            frameMax = max(frameMax, end)
            if key == modalKey {
                rows.append([clip["id"] ?? "", start, end - start, clip["textContent"] ?? ""])
            } else {
                deviants.append(clip)
            }
        }

        let total = rows.count
        if let window {
            rows = rows.filter { intValue($0[1]) < window.upperBound && intValue($0[1]) + intValue($0[2]) > window.lowerBound }
        }
        rows.sort { intValue($0[1]) < intValue($1[1]) }
        let shown = Array(rows.prefix(captionRowLimit))

        var group: [String: Any] = [
            "captionGroupId": gid,
            "clipCount": total,
            "frameRange": [frameMin, frameMax],
            "clipFormat": captionRowFormat,
            "clips": shown,
        ]
        if !shared.isEmpty { group["shared"] = shared }
        if shown.count < total {
            group["clipsNote"] = "Showing \(shown.count) of \(total) caption clips. Page with startFrame/endFrame."
        }
        return (group, deviants)
    }

    private static func canonicalJSON(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func clipIntersects(_ clip: [String: Any], _ window: Range<Int>) -> Bool {
        let start = intValue(clip["startFrame"])
        return start < window.upperBound && start + intValue(clip["durationFrames"]) > window.lowerBound
    }

    private static func intValue(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

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

        switch asset.type {
        case .image: return try readImage(asset: asset, args: args)
        case .video: return try await readVideo(editor: editor, asset: asset, args: args, mapping: mapping)
        case .audio: return try await readAudio(editor: editor, asset: asset, args: args, mapping: mapping)
        case .lottie: return try await readLottie(asset: asset, args: args)
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

        let rows: [(row: [Any], sourceEnd: Double)]
        if let mapping {
            rows = transcript.segments.compactMap { s in
                guard let f = spanFrames(start: s.start, end: s.end, clip: mapping.clip, fps: mapping.fps) else { return nil }
                return ([s.text, f.start, f.end], s.end)
            }
        } else {
            rows = transcript.segments.map { ([$0.text, round2OrNull($0.start), round2OrNull($0.end)], $0.end) }
        }
        out["segments"] = rows.prefix(inspectMaxSegments).map(\.row)
        if rows.count > inspectMaxSegments, let lastEnd = rows.prefix(inspectMaxSegments).last?.sourceEnd {
            out["totalSegments"] = rows.count
            out["nextStartSeconds"] = round2OrNull(lastEnd)
            out["segmentsNote"] = "First \(inspectMaxSegments) of \(rows.count) segments. Continue with startSeconds = nextStartSeconds."
        }

        if includeWords {
            let words: [[Any]]
            if let mapping {
                words = wordFrames(transcript, clip: mapping.clip, fps: mapping.fps).map { [$0.text, $0.start, $0.end] }
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

    private static let getTranscriptAllowedKeys: Set<String> = ["startFrame", "endFrame", "clipId", "wordTimestamps"]

    /// The live timeline transcript: every audio/video clip's words mapped to project
    /// frames and concatenated in timeline order
    func getTranscript(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.getTranscriptAllowedKeys, path: "get_transcript")
        let fps = editor.timeline.fps
        let clipFilter = args.string("clipId")
        let windowStart = args.int("startFrame")
        let windowEnd = args.int("endFrame")
        if let s = windowStart, let e = windowEnd, s >= e {
            throw ToolError("startFrame (\(s)) must be less than endFrame (\(e))")
        }

        let assetsById = Dictionary(editor.mediaAssets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        struct Frag { let clipId: String; let trackIndex: Int; let clip: Clip; let url: URL; let isVideo: Bool }
        var frags: [Frag] = []
        var isVideoByURL: [URL: Bool] = [:]
        for clip in editor.captionTargets(ids: []) {
            if let clipFilter, clip.id != clipFilter { continue }
            guard let loc = editor.findClip(id: clip.id), let asset = assetsById[clip.mediaRef] else { continue }
            let isVideo = asset.type == .video
            frags.append(Frag(clipId: clip.id, trackIndex: loc.trackIndex, clip: clip, url: asset.url, isVideo: isVideo))
            isVideoByURL[asset.url] = isVideo
        }
        if let clipFilter, frags.isEmpty {
            throw ToolError("Clip \(clipFilter) not found, or it has no audio/video to transcribe.")
        }

        // Transcribe each unique source once (cached); skip — don't fail — on per-asset errors.
        var transcripts: [URL: TranscriptionResult] = [:]
        var skipped: [[String: Any]] = []
        for url in Set(frags.map(\.url)) {
            do { transcripts[url] = try await TranscriptCache.shared.transcript(for: url, isVideo: isVideoByURL[url] ?? true, range: nil) }
            catch { skipped.append(["file": url.lastPathComponent, "reason": error.localizedDescription]) }
        }

        // Words are grouped under each clip as [text, start, end]. Paging is based on timeline order.
        var clipsOut: [[String: Any]] = []
        var totalWords = 0
        var remaining = Self.inspectMaxWords
        var lastEnd: Int?
        for frag in frags.sorted(by: { $0.clip.startFrame < $1.clip.startFrame }) {
            guard let transcript = transcripts[frag.url] else { continue }
            let visStart = Double(frag.clip.trimStartFrame)
            let visEnd = visStart + Double(frag.clip.durationFrames) * max(frag.clip.speed, 0.0001)
            var rows: [(start: Int, end: Int, row: [Any])] = []
            for w in transcript.words {
                guard let s = w.start, let e = w.end else { continue }
                // Assign a word to the clip whose visible range contains its midpoint.
                let midFrame = (s + e) / 2 * Double(fps)
                guard midFrame >= visStart, midFrame < visEnd,
                      let f = Self.spanFrames(start: s, end: e, clip: frag.clip, fps: fps) else { continue }
                if let ws = windowStart, f.end <= ws { continue }
                if let we = windowEnd, f.start >= we { continue }
                rows.append((f.start, f.end, [w.text, f.start, f.end]))
            }
            rows.sort { ($0.start, $0.end) < ($1.start, $1.end) }
            guard !rows.isEmpty else { continue }
            totalWords += rows.count
            guard remaining > 0 else { continue }
            let slice = rows.prefix(remaining)
            remaining -= slice.count
            lastEnd = slice.last?.end ?? lastEnd
            clipsOut.append(["clipId": frag.clipId, "trackIndex": frag.trackIndex,
                             "startFrame": frag.clip.startFrame, "endFrame": frag.clip.endFrame,
                             "words": slice.map(\.row)])
        }

        var out: [String: Any] = [
            "fps": fps, "timing": "projectFrames",
            "wordFormat": ["text", "start", "end"], "clips": clipsOut,
        ]
        if totalWords > Self.inspectMaxWords {
            out["totalWords"] = totalWords
            if let lastEnd {
                out["nextStartFrame"] = lastEnd
                out["wordsNote"] = "First \(Self.inspectMaxWords) of \(totalWords) words. Continue with startFrame = nextStartFrame."
            }
        }
        if !skipped.isEmpty { out["skipped"] = skipped }

        guard let json = Self.jsonString(out) else { throw ToolError("Failed to encode transcript") }
        return .ok(json)
    }

    /// Maps a clip's transcript words to (text, startFrame, endFrame) in project frames,
    /// dropping words that fall outside the clip's visible span.
    private static func wordFrames(_ transcript: TranscriptionResult, clip: Clip, fps: Int) -> [(text: String, start: Int, end: Int)] {
        transcript.words.compactMap { w in
            guard let s = w.start, let e = w.end, let f = spanFrames(start: s, end: e, clip: clip, fps: fps) else { return nil }
            return (w.text, f.start, f.end)
        }
    }

    /// Source-seconds span → project frames, clamped to the clip's visible window first so a boundary-straddler yields its real sliver, not a fabricated full-clip span. nil if not visible.
    private static func spanFrames(start: Double, end: Double, clip: Clip, fps: Int) -> (start: Int, end: Int)? {
        let fpsD = Double(fps)
        let visStart = Double(clip.trimStartFrame)
        let visEnd = visStart + Double(clip.durationFrames) * max(clip.speed, 0.0001)
        let s = max(start * fpsD, visStart)
        let e = min(end * fpsD, visEnd)
        guard e > s else { return nil }
        func toTimeline(_ sourceFrame: Double) -> Int {
            Int((Double(clip.startFrame) + (sourceFrame - visStart) / max(clip.speed, 0.0001)).rounded())
        }
        let a = toTimeline(s)
        return (a, max(a, toTimeline(e)))
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
        case .rendering: "rendering"
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
