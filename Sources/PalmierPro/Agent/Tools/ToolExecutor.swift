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

    private let editorProvider: () -> EditorViewModel?
    var editor: EditorViewModel? { editorProvider() }

    init(editor: EditorViewModel) {
        self.editorProvider = { [weak editor] in editor }
    }

    init(editorProvider: @escaping () -> EditorViewModel?) {
        self.editorProvider = editorProvider
    }

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
            case .addClips:      return try addClips(editor, args)
            case .removeClips:   return try removeClips(editor, args)
            case .updateClips:   return try updateClips(editor, args)
            case .moveClip:      return try moveClip(editor, args)
            case .splitClip:     return try splitClip(editor, args)
            case .addTexts:      return try addTexts(editor, args)
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
        case .audio: return try await readAudio(editor: editor, asset: asset, mapping: mapping)
        case .text: throw ToolError("Text clips are not stored as media assets.")
        }
    }

    private static func timelineMappingMeta(clip: Clip, fps: Int) -> [String: Any] {
        [
            "clipId": clip.id,
            "clipStartFrame": clip.startFrame,
            "clipEndFrame": clip.endFrame,
            "trimStartFrame": clip.trimStartFrame,
            "speed": clip.speed,
            "fps": fps,
            "note": "Per-word timelineStartFrame/timelineEndFrame are in project frames. Feed first word's timelineStartFrame as add_texts startFrame, (last word's timelineEnd - first word's timelineStart) as durationFrames.",
        ]
    }

    private func readImage(asset: MediaAsset, args: [String: Any]) throws -> ToolResult {
        let url = asset.url
        let maxBytes = args.int("maxImageBytes") ?? Self.defaultReadImageMaxBytes
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize <= UInt64(maxBytes) else {
            throw ToolError("Image file (\(fileSize) bytes) exceeds maxImageBytes (\(maxBytes))")
        }
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

        guard let metaJSON = Self.jsonString(meta) else { throw ToolError("Failed to encode metadata") }
        return ToolResult(
            content: [.image(base64: encoded.data.base64EncodedString(), mediaType: encoded.mime), .text(metaJSON)],
            isError: false
        )
    }

    private func readVideo(editor: EditorViewModel, asset: MediaAsset, args: [String: Any], mapping: (clip: Clip, fps: Int)? = nil) async throws -> ToolResult {
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
            guard let jpeg = ImageEncoder.encodeJPEG(cgImage, quality: Self.readVideoJPEGQuality) else { continue }
            frames.append((timestamp: t, data: jpeg))
        }
        guard !frames.isEmpty else { throw ToolError("Failed to extract frames from \(asset.name)") }

        var meta = Self.baseMeta(for: asset)
        meta["hasAudio"] = asset.hasAudio
        meta["frameTimestamps"] = frames.map(\.timestamp)

        if asset.hasAudio {
            do {
                let transcript = try await editor.generationService.transcribeVideoAudio(videoURL: asset.url)
                meta["transcription"] = Self.transcriptionMeta(from: transcript, mapping: mapping)
            } catch {
                Log.generation.error("video transcription failed: \(error.localizedDescription)")
                meta["transcriptionError"] = error.localizedDescription
            }
        }
        if let mapping { meta["timelineMapping"] = Self.timelineMappingMeta(clip: mapping.clip, fps: mapping.fps) }

        guard let metaJSON = Self.jsonString(meta) else { throw ToolError("Failed to encode metadata") }

        var blocks: [ToolResult.Block] = frames.map {
            .image(base64: $0.data.base64EncodedString(), mediaType: "image/jpeg")
        }
        blocks.append(.text(metaJSON))
        return ToolResult(content: blocks, isError: false)
    }

    private func readAudio(editor: EditorViewModel, asset: MediaAsset, mapping: (clip: Clip, fps: Int)? = nil) async throws -> ToolResult {
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
        for (k, v) in Self.transcriptionMeta(from: transcript, mapping: mapping) { meta[k] = v }
        if let mapping { meta["timelineMapping"] = Self.timelineMappingMeta(clip: mapping.clip, fps: mapping.fps) }
        guard let metaJSON = Self.jsonString(meta) else { throw ToolError("Failed to encode metadata") }
        return .ok(metaJSON)
    }

    private static func transcriptionMeta(
        from transcript: GenerationService.TranscriptionResult,
        mapping: (clip: Clip, fps: Int)? = nil
    ) -> [String: Any] {
        var out: [String: Any] = [
            "text": transcript.text,
            "words": transcript.words.map { w -> [String: Any] in
                var entry: [String: Any] = ["text": w.text, "type": w.type]
                if let s = w.start { entry["start"] = s }
                if let e = w.end { entry["end"] = e }
                if let sid = w.speakerId { entry["speakerId"] = sid }
                if let mapping {
                    if let s = w.start, let tf = mapping.clip.timelineFrame(sourceSeconds: s, fps: mapping.fps) {
                        entry["timelineStartFrame"] = tf
                    }
                    if let e = w.end, let tf = mapping.clip.timelineFrame(sourceSeconds: e, fps: mapping.fps) {
                        entry["timelineEndFrame"] = tf
                    }
                }
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

    private func addTrack(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let typeStr = try args.requireString("type")
        guard let type = ClipType(rawValue: typeStr) else {
            throw ToolError("Invalid 'type'. Must be: video, audio, image")
        }
        let label = args.string("label") ?? type.trackLabel
        // insertTrack clamps audio tracks into the audio zone even when asked for 0.
        let index = editor.insertTrack(at: 0, type: type, label: label)
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

    private struct AddClipSpec {
        let asset: MediaAsset
        let trackIndex: Int
        let startFrame: Int
        let durationFrames: Int
    }

    private static let addClipsAllowedKeys: Set<String> = ["mediaRef", "trackIndex", "startFrame", "durationFrames"]

    private func addClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let rawEntries = args["entries"] as? [Any], !rawEntries.isEmpty else {
            throw ToolError("Missing or empty 'entries' array")
        }
        var specs: [AddClipSpec] = []
        specs.reserveCapacity(rawEntries.count)

        for (idx, raw) in rawEntries.enumerated() {
            guard let entry = raw as? [String: Any] else {
                throw ToolError("entries[\(idx)] must be an object")
            }
            try validateUnknownKeys(entry, allowed: Self.addClipsAllowedKeys, path: "entries[\(idx)]")
            let mediaRef = try entry.requireString("mediaRef")
            let trackIndex = try entry.requireInt("trackIndex")
            let startFrame = try entry.requireInt("startFrame")
            let durationFrames = try entry.requireInt("durationFrames")

            guard editor.timeline.tracks.indices.contains(trackIndex) else {
                throw ToolError("entries[\(idx)]: track index \(trackIndex) out of range (0..\(editor.timeline.tracks.count - 1))")
            }
            let asset = try asset(mediaRef, editor: editor)
            let targetType = editor.timeline.tracks[trackIndex].type
            guard asset.type.isCompatible(with: targetType) else {
                throw ToolError("entries[\(idx)]: asset type \(asset.type.rawValue) is not compatible with \(targetType.rawValue) track at index \(trackIndex)")
            }
            guard durationFrames >= 1 else {
                throw ToolError("entries[\(idx)]: durationFrames must be >= 1 (got \(durationFrames))")
            }
            specs.append(.init(asset: asset, trackIndex: trackIndex, startFrame: startFrame, durationFrames: durationFrames))
        }

        var allAdded: [String] = []
        var summaries: [String] = []
        editor.undoManager?.beginUndoGrouping()
        // Per-track startFrame order so earlier-starting clips get trimmed, not later ones.
        let orderedIndices = specs.indices.sorted {
            (specs[$0].trackIndex, specs[$0].startFrame) < (specs[$1].trackIndex, specs[$1].startFrame)
        }
        for i in orderedIndices {
            let spec = specs[i]
            editor.clearRegion(trackIndex: spec.trackIndex, start: spec.startFrame, end: spec.startFrame + spec.durationFrames)
            let ids = editor.placeClip(
                asset: spec.asset, trackIndex: spec.trackIndex,
                startFrame: spec.startFrame, durationFrames: spec.durationFrames
            )
            allAdded.append(contentsOf: ids)
            let primary = ids.first ?? "?"
            let pairedNote = ids.count > 1 ? " (+linked audio \(ids[1]))" : ""
            summaries.append("\(primary) on track \(spec.trackIndex) @ \(spec.startFrame) for \(spec.durationFrames)\(pairedNote)")
        }
        let addedIds = allAdded
        editor.undoManager?.registerUndo(withTarget: editor) { vm in
            vm.removeClips(ids: Set(addedIds))
        }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName(specs.count == 1 ? "Add Clip (Agent)" : "Add Clips (Agent)")
        editor.notifyTimelineChanged()

        return .ok("Added \(specs.count) clip\(specs.count == 1 ? "" : "s"): \(summaries.joined(separator: "; "))")
    }

    private func removeClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["clipIds"], path: "remove_clips")
        let clipIds = args.stringArray("clipIds")
        guard !clipIds.isEmpty else { throw ToolError("Missing or empty 'clipIds' array") }
        for id in clipIds {
            guard editor.findClip(id: id) != nil else { throw ToolError("Clip not found: \(id)") }
        }
        let expanded = editor.expandToLinkGroup(Set(clipIds))
        editor.removeClips(ids: expanded)
        let extras = expanded.count - clipIds.count
        let note = extras > 0 ? " (+\(extras) linked)" : ""
        return .ok("Removed \(expanded.count) clip\(expanded.count == 1 ? "" : "s")\(note): \(clipIds.joined(separator: ", "))")
    }

    private static let updateClipsAllowedKeys: Set<String> = [
        "clipId",
        "startFrame", "durationFrames", "trimStartFrame", "trimEndFrame",
        "speed", "volume", "opacity",
        "transform",
        "content", "fontName", "fontSize", "color", "alignment",
    ]
    private static let textOnlyKeys: Set<String> = ["content", "fontName", "fontSize", "color", "alignment"]

    private struct ParsedClipUpdate {
        let clipId: String
        let isText: Bool
        let startFrame: Int?
        let durationFrames: Int?
        let trimStartFrame: Int?
        let trimEndFrame: Int?
        let speed: Double?
        let volume: Double?
        let opacity: Double?
        let transform: (cx: Double?, cy: Double?, w: Double?, h: Double?)?
        let content: String?
        let fontName: String?
        let fontSize: Double?
        let color: TextStyle.RGBA?
        let alignment: TextStyle.Alignment?
    }

    private func updateClips(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let rawUpdates = args["updates"] as? [Any], !rawUpdates.isEmpty else {
            throw ToolError("Missing or empty 'updates' array")
        }

        // Parse + validate every entry before any mutation; fail-fast keeps timeline clean.
        var parsed: [ParsedClipUpdate] = []
        parsed.reserveCapacity(rawUpdates.count)

        for (idx, raw) in rawUpdates.enumerated() {
            let path = "updates[\(idx)]"
            guard let entry = raw as? [String: Any] else {
                throw ToolError("\(path) must be an object")
            }
            try validateUnknownKeys(entry, allowed: Self.updateClipsAllowedKeys, path: path)

            let clipId = try entry.requireString("clipId")
            guard let loc = editor.findClip(id: clipId) else {
                throw ToolError("\(path): clip not found: \(clipId)")
            }
            let clipType = editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].mediaType
            let isText = clipType == .text

            let textOnlySeen = Set(entry.keys).intersection(Self.textOnlyKeys)
            if !isText && !textOnlySeen.isEmpty {
                throw ToolError("\(path): clip \(clipId) is a \(clipType.rawValue) clip; fields '\(textOnlySeen.sorted().joined(separator: "', '"))' are only valid on text clips")
            }

            var transform: (cx: Double?, cy: Double?, w: Double?, h: Double?)?
            if let tDict = entry["transform"] as? [String: Any] {
                try validateUnknownKeys(tDict, allowed: ["centerX", "centerY", "width", "height"], path: "\(path).transform")
                let cx = tDict.double("centerX")
                let cy = tDict.double("centerY")
                let w = tDict.double("width")
                let h = tDict.double("height")
                if cx != nil || cy != nil || w != nil || h != nil {
                    transform = (cx, cy, w, h)
                }
            }

            parsed.append(.init(
                clipId: clipId,
                isText: isText,
                startFrame: entry.int("startFrame"),
                durationFrames: entry.int("durationFrames"),
                trimStartFrame: entry.int("trimStartFrame"),
                trimEndFrame: entry.int("trimEndFrame"),
                speed: entry.double("speed"),
                volume: entry.double("volume"),
                opacity: entry.double("opacity"),
                transform: transform,
                content: entry.string("content"),
                fontName: entry.string("fontName"),
                fontSize: entry.double("fontSize"),
                color: try parseColorHex(entry.string("color"), path: path),
                alignment: try parseAlignment(entry.string("alignment"), path: path)
            ))
        }

        editor.undoManager?.beginUndoGrouping()
        var summaries: [String] = []
        for u in parsed {
            var changed: [String] = []
            editor.commitClipProperty(clipId: u.clipId) { clip in
                if let v = u.startFrame { clip.startFrame = v; changed.append("startFrame") }
                if let v = u.durationFrames {
                    clip.durationFrames = v
                    clip.clampFadesToDuration()
                    changed.append("durationFrames")
                }
                if let v = u.trimStartFrame { clip.trimStartFrame = v; changed.append("trimStartFrame") }
                if let v = u.trimEndFrame { clip.trimEndFrame = v; changed.append("trimEndFrame") }
                if let v = u.speed { clip.speed = v; changed.append("speed") }
                if let v = u.volume { clip.volume = v; changed.append("volume") }
                if let v = u.opacity { clip.opacity = v; changed.append("opacity") }

                if let t = u.transform {
                    let cur = clip.transform
                    let center = cur.center
                    let cx = t.cx ?? center.x
                    let cy = t.cy ?? center.y
                    let w = t.w ?? cur.width
                    let h = t.h ?? cur.height
                    clip.transform = Transform(center: (cx, cy), width: w, height: h)
                    changed.append("transform")
                }

                if u.isText {
                    if let c = u.content { clip.textContent = c; changed.append("content") }
                    var style = clip.textStyle ?? TextStyle()
                    if let f = u.fontName { style.fontName = f; changed.append("fontName") }
                    if let s = u.fontSize { style.fontSize = s; changed.append("fontSize") }
                    if let c = u.color { style.color = c; changed.append("color") }
                    if let a = u.alignment { style.alignment = a; changed.append("alignment") }
                    clip.textStyle = style
                }
            }

            // Match the inspector: refit bbox after content/font change when caller didn't set a box.
            if u.isText && u.transform == nil && (u.content != nil || u.fontName != nil || u.fontSize != nil) {
                editor.fitTextClipToContent(clipId: u.clipId)
            }

            summaries.append("\(u.clipId)\(changed.isEmpty ? " (no-op)" : ": \(changed.joined(separator: ", "))")")
        }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName(parsed.count == 1 ? "Update Clip (Agent)" : "Update Clips (Agent)")

        return .ok("Updated \(parsed.count) clip\(parsed.count == 1 ? "" : "s"): \(summaries.joined(separator: "; "))")
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

    private static let addTextsAllowedKeys: Set<String> = [
        "trackIndex", "startFrame", "durationFrames", "content",
        "transform", "fontName", "fontSize", "color", "alignment",
    ]

    /// Accepts nil (centered auto-fit), {centerX, centerY} (auto-fit at that center),
    /// or all four of {centerX, centerY, width, height}. Any other partial combination throws.
    private func parseAddTextTransform(
        _ tDict: [String: Any]?,
        content: String, style: TextStyle,
        canvas: (w: Double, h: Double),
        path: String
    ) throws -> Transform? {
        guard let tDict else { return nil }
        try validateUnknownKeys(tDict, allowed: ["centerX", "centerY", "width", "height"], path: "\(path).transform")
        let cX = tDict.double("centerX"), cY = tDict.double("centerY")
        let w = tDict.double("width"), h = tDict.double("height")
        if cX == nil && cY == nil && w == nil && h == nil { return nil }
        guard let cx = cX, let cy = cY else {
            throw ToolError("\(path): transform must be either {centerX, centerY} for auto-fit, or all four of {centerX, centerY, width, height}")
        }
        if let ww = w, let hh = h {
            return Transform(center: (cx, cy), width: ww, height: hh)
        }
        guard w == nil && h == nil else {
            throw ToolError("\(path): transform must be either {centerX, centerY} for auto-fit, or all four of {centerX, centerY, width, height}")
        }
        let natural = TextLayout.naturalSize(content: content, style: style, maxWidth: CGFloat(canvas.w) * 0.9)
        return Transform(center: (cx, cy), width: Double(natural.width) / canvas.w, height: Double(natural.height) / canvas.h)
    }

    private struct PartialTextSpec {
        let trackIndex: Int?
        let startFrame: Int
        let durationFrames: Int
        let content: String
        let style: TextStyle
        let transform: Transform?
    }

    private func addTexts(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let rawEntries = args["entries"] as? [Any], !rawEntries.isEmpty else {
            throw ToolError("Missing or empty 'entries' array")
        }

        var partials: [PartialTextSpec] = []
        partials.reserveCapacity(rawEntries.count)

        for (idx, raw) in rawEntries.enumerated() {
            let path = "entries[\(idx)]"
            guard let entry = raw as? [String: Any] else {
                throw ToolError("\(path) must be an object")
            }
            try validateUnknownKeys(entry, allowed: Self.addTextsAllowedKeys, path: path)

            let trackIndex = entry.int("trackIndex")
            let startFrame = try entry.requireInt("startFrame")
            let durationFrames = try entry.requireInt("durationFrames")
            let content = try entry.requireString("content")

            if let ti = trackIndex {
                guard editor.timeline.tracks.indices.contains(ti) else {
                    throw ToolError("\(path): track index \(ti) out of range (0..\(editor.timeline.tracks.count - 1))")
                }
                guard ClipType.text.isCompatible(with: editor.timeline.tracks[ti].type) else {
                    throw ToolError("\(path): track \(ti) is an audio track; text requires a video/image/text track")
                }
            }
            guard durationFrames >= 1 else {
                throw ToolError("\(path): durationFrames must be >= 1 (got \(durationFrames))")
            }

            var style = TextStyle()
            if let f = entry.string("fontName") { style.fontName = f }
            if let s = entry.double("fontSize") { style.fontSize = s }
            if let c = try parseColorHex(entry.string("color"), path: path) { style.color = c }
            if let a = try parseAlignment(entry.string("alignment"), path: path) { style.alignment = a }

            let transform = try parseAddTextTransform(
                entry["transform"] as? [String: Any],
                content: content, style: style,
                canvas: (Double(editor.timeline.width), Double(editor.timeline.height)),
                path: path
            )

            partials.append(.init(
                trackIndex: trackIndex,
                startFrame: startFrame,
                durationFrames: durationFrames,
                content: content,
                style: style,
                transform: transform
            ))
        }

        // All-or-none: a new track at index 0 would shift any explicit indices.
        let omittedCount = partials.filter { $0.trackIndex == nil }.count
        guard omittedCount == 0 || omittedCount == partials.count else {
            throw ToolError("Mixed trackIndex: \(omittedCount) of \(partials.count) entries omitted trackIndex. Either set it on every entry or omit it on every entry (to auto-create a shared new track).")
        }

        editor.undoManager?.beginUndoGrouping()
        var createdTrackInfo: String? = nil
        let resolvedSpecs: [EditorViewModel.TextClipSpec]
        if omittedCount == partials.count {
            let label = "T\(editor.zones.videoTrackCount + 1)"
            let newIdx = editor.insertTrack(at: 0, type: .video, label: label)
            createdTrackInfo = "track \(newIdx) ('\(label)')"
            resolvedSpecs = partials.map {
                .init(
                    trackIndex: newIdx,
                    startFrame: $0.startFrame,
                    durationFrames: $0.durationFrames,
                    content: $0.content,
                    style: $0.style,
                    transform: $0.transform
                )
            }
        } else {
            resolvedSpecs = partials.map {
                .init(
                    trackIndex: $0.trackIndex!,
                    startFrame: $0.startFrame,
                    durationFrames: $0.durationFrames,
                    content: $0.content,
                    style: $0.style,
                    transform: $0.transform
                )
            }
        }

        let ids = editor.placeTextClips(resolvedSpecs)
        guard !ids.isEmpty else {
            editor.undoManager?.endUndoGrouping()
            throw ToolError("Failed to place any text clips")
        }

        editor.undoManager?.registerUndo(withTarget: editor) { vm in
            vm.removeClips(ids: Set(ids))
        }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName(ids.count == 1 ? "Add Text (Agent)" : "Add Texts (Agent)")
        editor.notifyTimelineChanged()

        let prefix = createdTrackInfo.map { "Created \($0). " } ?? ""
        let summary = zip(ids, resolvedSpecs).map { id, spec in
            "\(id) on track \(spec.trackIndex) @ frame \(spec.startFrame) for \(spec.durationFrames)"
        }.joined(separator: "; ")
        return .ok("\(prefix)Added \(ids.count) text clip\(ids.count == 1 ? "" : "s"): \(summary)")
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
        guard sourceAsset.type == .video else {
            throw ToolError("sourceVideoMediaRef must reference a video asset")
        }

        var refs: [MediaAsset] = [sourceAsset]
        if model.supportsReferences {
            let imgRefIds = args.stringArray("referenceImageMediaRefs")
            if imgRefIds.count > model.maxReferenceImages {
                throw ToolError("\(model.displayName) accepts at most \(model.maxReferenceImages) image reference(s)")
            }
            for id in imgRefIds {
                let a = try asset(id, editor: editor, label: "Reference image")
                guard a.type == .image else {
                    throw ToolError("referenceImageMediaRefs entry '\(id)' must be an image asset")
                }
                refs.append(a)
            }
        }

        if let err = model.validate(duration: 0, aspectRatio: "", resolution: nil) {
            throw ToolError(err)
        }

        let genInput = GenerationInput(
            prompt: prompt, model: model.id, duration: Int(sourceAsset.duration.rounded()),
            aspectRatio: "", resolution: nil
        )
        let placeholderId = editor.generationService.generate(
            genInput: genInput, assetType: .video,
            placeholderDuration: sourceAsset.duration > 0 ? sourceAsset.duration : 5,
            references: refs, name: args.string("name"),
            variantStackRootId: editor.stackRootId(for: sourceAsset),
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

        func typedRefs(_ argName: String, expected: ClipType) throws -> [MediaAsset] {
            try args.stringArray(argName).map { id in
                let a = try asset(id, editor: editor, label: "\(expected.rawValue) reference")
                guard a.type == expected else {
                    throw ToolError("\(argName) entry '\(id)' must be a \(expected.rawValue) asset")
                }
                return a
            }
        }
        let imageRefs = try typedRefs("referenceImageMediaRefs", expected: .image)
        let videoRefs = try typedRefs("referenceVideoMediaRefs", expected: .video)
        let audioRefs = try typedRefs("referenceAudioMediaRefs", expected: .audio)

        if model.framesAndReferencesExclusive,
           !frameSlots.isEmpty, !(imageRefs.isEmpty && videoRefs.isEmpty && audioRefs.isEmpty) {
            throw ToolError("\(model.displayName) uses frames OR references, not both. Clear one side.")
        }
        if imageRefs.count > model.maxReferenceImages {
            throw ToolError("\(model.displayName) accepts at most \(model.maxReferenceImages) image references")
        }
        if videoRefs.count > model.maxReferenceVideos {
            throw ToolError("\(model.displayName) accepts at most \(model.maxReferenceVideos) video references")
        }
        if audioRefs.count > model.maxReferenceAudios {
            throw ToolError("\(model.displayName) accepts at most \(model.maxReferenceAudios) audio references")
        }
        let totalRefs = imageRefs.count + videoRefs.count + audioRefs.count
        if let totalCap = model.maxTotalReferences, totalRefs > totalCap {
            throw ToolError("\(model.displayName) accepts at most \(totalCap) references total")
        }
        if let cap = model.maxCombinedVideoRefSeconds,
           videoRefs.reduce(0, { $0 + $1.duration }) > cap {
            throw ToolError("Combined video reference duration exceeds \(Int(cap))s")
        }
        if let cap = model.maxCombinedAudioRefSeconds,
           audioRefs.reduce(0, { $0 + $1.duration }) > cap {
            throw ToolError("Combined audio reference duration exceeds \(Int(cap))s")
        }

        var refs: [MediaAsset] = []
        refs.append(contentsOf: frameSlots)
        refs.append(contentsOf: imageRefs)
        refs.append(contentsOf: videoRefs)
        refs.append(contentsOf: audioRefs)
        let frameCount = frameSlots.count
        let imageRefCount = imageRefs.count
        let videoRefCount = videoRefs.count
        let audioRefCount = audioRefs.count

        let genInput = GenerationInput(
            prompt: prompt, model: model.id, duration: duration,
            aspectRatio: aspectRatio, resolution: resolution
        )
        let snapshotRefs: (@Sendable (inout GenerationInput, [String]) -> Void) = { input, uploaded in
            let frames = Array(uploaded.prefix(frameCount))
            let rest = Array(uploaded.dropFirst(frameCount))
            input.imageURLs = frames.isEmpty ? nil : frames
            input.referenceImageURLs = imageRefCount > 0 ? Array(rest.prefix(imageRefCount)) : nil
            input.referenceVideoURLs = videoRefCount > 0
                ? Array(rest.dropFirst(imageRefCount).prefix(videoRefCount)) : nil
            input.referenceAudioURLs = audioRefCount > 0
                ? Array(rest.dropFirst(imageRefCount + videoRefCount).prefix(audioRefCount)) : nil
        }
        var preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)? = nil
        if videoRefCount > 0 {
            preprocessRef = { _, a in
                guard a.type == .video else { return nil }
                return try await VideoCompressor.compressIfNeeded(url: a.url)
            }
        }

        let groupRoot = args.string("groupWithMediaRef").flatMap { editor.stackRootId(forAssetId: $0) }
        let placeholderId = editor.generationService.generate(
            genInput: genInput, assetType: .video,
            placeholderDuration: Double(max(1, duration)),
            references: refs, name: args.string("name"),
            variantStackRootId: groupRoot,
            buildInput: { uploaded in
                let frames = Array(uploaded.prefix(frameCount))
                let rest = Array(uploaded.dropFirst(frameCount))
                let params = VideoGenerationParams(
                    prompt: prompt, duration: duration,
                    aspectRatio: aspectRatio, resolution: resolution,
                    sourceVideoURL: nil,
                    startFrameURL: frames.first,
                    endFrameURL: frames.count > 1 ? frames[1] : nil,
                    referenceImageURLs: Array(rest.prefix(imageRefCount)),
                    referenceVideoURLs: Array(rest.dropFirst(imageRefCount).prefix(videoRefCount)),
                    referenceAudioURLs: Array(rest.dropFirst(imageRefCount + videoRefCount).prefix(audioRefCount)),
                    generateAudio: true
                )
                return (model.resolvedEndpoint(params: params), model.buildInput(params: params))
            },
            snapshotRefs: snapshotRefs,
            preprocessRef: preprocessRef,
            responseKeyPath: FalResponsePaths.video,
            fileExtension: "mp4",
            projectURL: editor.projectURL, editor: editor
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
        let modelId = args.string("model") ?? ImageModelConfig.allModels[0].id
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
        let groupRoot = args.string("groupWithMediaRef").flatMap { editor.stackRootId(forAssetId: $0) }
        let placeholderId = editor.generationService.generate(
            genInput: genInput, assetType: .image,
            placeholderDuration: Defaults.imageDurationSeconds,
            references: refs, name: args.string("name"),
            variantStackRootId: groupRoot,
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

        let groupRoot = args.string("groupWithMediaRef").flatMap { editor.stackRootId(forAssetId: $0) }
        let placeholderId = editor.generationService.generate(
            genInput: genInput, assetType: .audio,
            placeholderDuration: placeholderDuration,
            name: args.string("name"),
            variantStackRootId: groupRoot,
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

/// Throws if `entry` carries any keys outside `allowed`. `path` prefixes the error (e.g. "entries[3]").
func validateUnknownKeys(_ entry: [String: Any], allowed: Set<String>, path: String) throws {
    let unknown = Set(entry.keys).subtracting(allowed)
    guard unknown.isEmpty else {
        throw ToolError("\(path): unknown field(s) '\(unknown.sorted().joined(separator: "', '"))'. Allowed: \(allowed.sorted().joined(separator: ", ")).")
    }
}

func parseColorHex(_ hex: String?, path: String) throws -> TextStyle.RGBA? {
    guard let hex else { return nil }
    guard let c = TextStyle.RGBA(hex: hex) else {
        throw ToolError("\(path): invalid color '\(hex)'. Expected '#RRGGBB' or '#RRGGBBAA'.")
    }
    return c
}

func parseAlignment(_ raw: String?, path: String) throws -> TextStyle.Alignment? {
    guard let raw else { return nil }
    guard let a = TextStyle.Alignment(rawValue: raw) else {
        throw ToolError("\(path): invalid alignment '\(raw)'. Expected 'left', 'center', or 'right'.")
    }
    return a
}

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
