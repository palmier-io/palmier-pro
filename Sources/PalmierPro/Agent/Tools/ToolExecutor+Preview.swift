import CoreFoundation
import Foundation
import MCP

extension ToolExecutor {
    private static let showPreviewAllowedKeys: Set<String> = [
        "mediaRef", "mediaRefs", "clipId", "timelineId",
        "startFrame", "endFrame", "maxFrames", "look",
    ]
    private static let lookAllowedKeys: Set<String> = [
        "style", "transform", "animation", "highlightColor", "sampleText",
    ]

    func showPreview(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.showPreviewAllowedKeys, path: "show_preview")
        let mediaIDs = uniqueMediaIDs(args)
        let hasLook = args.keys.contains("look")
        let hasRange = args.keys.contains("startFrame") || args.keys.contains("endFrame")
        if !mediaIDs.isEmpty, hasLook {
            throw ToolError("show_preview: look cannot be combined with mediaRef/mediaRefs.")
        }
        if !mediaIDs.isEmpty, hasRange {
            throw ToolError("show_preview: startFrame/endFrame cannot be combined with mediaRef/mediaRefs.")
        }
        if mediaIDs.isEmpty, !hasLook, !hasRange {
            throw ToolError("show_preview requires mediaRef, mediaRefs, a timeline range, or look.")
        }
        if !mediaIDs.isEmpty {
            return try await showAssetPreview(editor, args, ids: mediaIDs)
        }
        return try await showTimelinePreview(editor, args, look: hasLook)
    }

    private func uniqueMediaIDs(_ args: [String: Any]) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        func append(_ id: String) {
            guard seen.insert(id).inserted else { return }
            ids.append(id)
        }
        if let single = args.string("mediaRef") { append(single) }
        for id in args.stringArray("mediaRefs") { append(id) }
        return ids
    }

    private func showAssetPreview(
        _ editor: EditorViewModel,
        _ args: [String: Any],
        ids: [String]
    ) async throws -> ToolResult {
        guard ids.count <= MCPPreviewApp.maxAssets else {
            throw ToolError("show_preview accepts at most \(MCPPreviewApp.maxAssets) assets.")
        }
        let clipId = args.string("clipId")
        if let clipId {
            guard editor.findClip(id: clipId) != nil else {
                throw ToolError("Clip not found: \(clipId)")
            }
        }

        var items: [PreviewItem] = []
        items.reserveCapacity(ids.count)
        for id in ids {
            items.append(try await previewItem(id, editor: editor, clipId: clipId))
        }

        var payload: [String: Any] = [
            "intent": "assets",
            "items": items.map(\.json),
            "playheadFrame": editor.currentFrame,
            "timelineId": editor.timeline.id,
        ]
        if let clipId { payload["clipId"] = clipId }
        if let first = items.first {
            payload["mediaRef"] = first.mediaRef
            payload["name"] = first.name
            payload["type"] = first.kind.rawValue
            if let url = first.url { payload[first.kind.urlKey] = url }
            if let eventsURL = first.eventsURL { payload["eventsUrl"] = eventsURL }
            if let width = first.width { payload["width"] = width }
            if let height = first.height { payload["height"] = height }
            if let duration = first.durationSeconds { payload["durationSeconds"] = duration }
            if let generation = first.generation { payload["generation"] = generation.json }
        }
        return try previewResult(payload, structured: .object([
            "intent": .string("assets"),
            "items": .array(items.map(\.value)),
            "playheadFrame": .int(editor.currentFrame),
            "timelineId": .string(editor.timeline.id),
        ].merging(clipId.map { ["clipId": .string($0)] } ?? [:]) { _, new in new }))
    }

    private func showTimelinePreview(
        _ editor: EditorViewModel,
        _ args: [String: Any],
        look: Bool
    ) async throws -> ToolResult {
        let timeline: Timeline
        if let timelineId = args.string("timelineId") {
            guard let resolved = editor.timeline(for: timelineId) else {
                throw ToolError("Timeline not found: \(timelineId)")
            }
            timeline = resolved
        } else {
            timeline = editor.timeline
        }

        let range = try previewRange(args, timeline: timeline, playhead: editor.currentFrame, expand: look)
        var lookRequest: LookPreview?
        if look {
            var parsed = try parseLook(args["look"])
            parsed.captionGroupIds = captionGroupIds(in: timeline, range: range)
            lookRequest = parsed
        }
        var renderTimeline = timeline
        if let lookRequest {
            renderTimeline = applyLook(lookRequest, to: timeline, editor: editor, range: range)
        }

        let sampled = try await TimelineFrameSampler.sample(
            timeline: renderTimeline,
            editor: editor,
            startFrame: range.start,
            endFrame: range.end,
            maxFrames: args.int("maxFrames") ?? 8,
            burnLabels: lookRequest == nil
        )

        var frameItems: [[String: Any]] = []
        var frameValues: [Value] = []
        for frame in sampled {
            let token = await MCPPreviewStore.shared.registerBlob(frame.jpeg, mimeType: "image/jpeg")
            let url = MCPPreviewApp.blobURL(token: token)
            frameItems.append([
                "frame": frame.frame,
                "url": url,
                "clips": frame.clipIds,
                "width": frame.width,
                "height": frame.height,
            ])
            frameValues.append(.object([
                "frame": .int(frame.frame),
                "url": .string(url),
                "clips": .array(frame.clipIds.map { .string($0) }),
                "width": .int(frame.width),
                "height": .int(frame.height),
            ]))
        }

        let intent = lookRequest == nil ? "cut" : "look"
        var payload: [String: Any] = [
            "intent": intent,
            "timelineId": timeline.id,
            "startFrame": range.start,
            "endFrame": range.end,
            "fps": timeline.fps,
            "width": sampled[0].width,
            "height": sampled[0].height,
            "totalFrames": timeline.totalFrames,
            "frames": frameItems,
            "mutated": false,
        ]
        var structured: [String: Value] = [
            "intent": .string(intent),
            "timelineId": .string(timeline.id),
            "startFrame": .int(range.start),
            "endFrame": .int(range.end),
            "fps": .int(timeline.fps),
            "width": .int(sampled[0].width),
            "height": .int(sampled[0].height),
            "totalFrames": .int(timeline.totalFrames),
            "frames": .array(frameValues),
            "mutated": .bool(false),
        ]
        if let lookRequest {
            payload["look"] = lookRequest.json
            payload["applyLook"] = lookRequest.applyCalls
            structured["look"] = lookRequest.value
            structured["applyLook"] = .array(lookRequest.applyCallValues)
        }
        return try previewResult(payload, structured: .object(structured))
    }

    private func previewRange(
        _ args: [String: Any],
        timeline: Timeline,
        playhead: Int,
        expand: Bool
    ) throws -> (start: Int, end: Int) {
        let total = timeline.totalFrames
        guard total > 0 else { throw ToolError("Timeline is empty — nothing to render.") }
        let startArg = args.int("startFrame")
        let endArg = args.int("endFrame")
        if let startArg, let endArg {
            guard endArg > startArg else {
                throw ToolError("endFrame must be greater than startFrame (\(startArg)).")
            }
            let start = max(0, min(startArg, total - 1))
            return (start, min(endArg, total))
        }
        if let startArg, !expand {
            guard startArg >= 0, startArg < total else {
                throw ToolError("startFrame \(startArg) out of range [0, \(total)).")
            }
            return (startArg, min(startArg + 1, total))
        }
        let window = min(max(1, timeline.fps * 3), total)
        let origin = startArg ?? playhead
        let start = max(0, min(origin, total - window))
        return (start, start + window)
    }

    private func parseLook(_ raw: Any?) throws -> LookPreview {
        guard let raw else {
            throw ToolError("show_preview.look: expected object")
        }
        guard let object = raw as? [String: Any] else {
            throw ToolError("show_preview.look: expected object")
        }
        try validateUnknownKeys(object, allowed: Self.lookAllowedKeys, path: "show_preview.look")
        let stylePatch = try parseTextStylePatch(object, path: "show_preview.look")
        let transform = try parseTextTransform(object["transform"], path: "show_preview.look.transform")
        let animation = try parseTextAnimation(
            preset: object.string("animation"),
            highlightColor: object.string("highlightColor"),
            path: "show_preview.look"
        )
        let sampleText = object.string("sampleText")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if sampleText == "" {
            throw ToolError("show_preview.look.sampleText must be a non-empty string.")
        }
        guard stylePatch?.hasAnyField == true || transform != nil || animation != nil || sampleText != nil else {
            throw ToolError("show_preview.look needs style, transform, animation, or sampleText.")
        }
        return LookPreview(
            stylePatch: stylePatch,
            transform: transform,
            animation: animation,
            sampleText: sampleText,
            raw: object,
            captionGroupIds: []
        )
    }

    private func captionGroupIds(in timeline: Timeline, range: (start: Int, end: Int)) -> [String] {
        var ids: [String] = []
        var seen = Set<String>()
        for track in timeline.tracks {
            for clip in track.clips {
                guard clip.startFrame < range.end, clip.endFrame > range.start else { continue }
                guard let gid = clip.captionGroupId, seen.insert(gid).inserted else { continue }
                ids.append(gid)
            }
        }
        return ids
    }

    private func applyLook(
        _ look: LookPreview,
        to timeline: Timeline,
        editor: EditorViewModel,
        range: (start: Int, end: Int)
    ) -> Timeline {
        var copy = timeline
        var touched = false
        let canvasW = Double(copy.width)
        let canvasH = Double(copy.height)
        for ti in copy.tracks.indices {
            for ci in copy.tracks[ti].clips.indices {
                var clip = copy.tracks[ti].clips[ci]
                guard clip.mediaType == .text else { continue }
                guard clip.startFrame < range.end, clip.endFrame > range.start else { continue }
                applyLook(look, to: &clip, editor: editor, canvasW: canvasW, canvasH: canvasH)
                copy.tracks[ti].clips[ci] = clip
                touched = true
            }
        }
        guard !touched else { return copy }
        var clip = Clip(
            mediaRef: "",
            startFrame: range.start,
            durationFrames: max(1, range.end - range.start)
        )
        clip.mediaType = .text
        clip.sourceClipType = .text
        clip.textContent = look.sampleText?.isEmpty == false ? look.sampleText : "Sample caption"
        var style = TextStyle.caption
        if let patch = look.stylePatch {
            Self.applyTextStylePatch(patch, to: &style)
        }
        clip.textStyle = style
        clip.textAnimation = look.animation
        let content = clip.textContent ?? "Sample caption"
        let natural = TextLayout.naturalSize(
            content: content,
            style: style,
            maxWidth: CGFloat(canvasW) * AppTheme.ComponentSize.captionPreviewMaxTextWidthRatio,
            canvasHeight: CGFloat(canvasH)
        )
        let width = Double(natural.width) / canvasW
        let height = Double(natural.height) / canvasH
        let anchorX = look.transform?.x ?? Double(AppTheme.Caption.defaultCenter.x)
        clip.transform = Transform(
            centerX: Self.textCenterX(anchorX: anchorX, width: width, alignment: style.alignment),
            centerY: look.transform?.y ?? Double(AppTheme.Caption.defaultCenter.y),
            width: width,
            height: height,
            rotation: look.transform?.rotation ?? 0,
            rotationX: look.transform?.rotationX ?? 0,
            rotationY: look.transform?.rotationY ?? 0
        )
        _ = editor.fitTextClipToContentIfNeeded(&clip, canvasW: canvasW, canvasH: canvasH)
        copy.tracks.insert(Track(type: .video, clips: [clip]), at: 0)
        return copy
    }

    private func applyLook(
        _ look: LookPreview,
        to clip: inout Clip,
        editor: EditorViewModel,
        canvasW: Double,
        canvasH: Double
    ) {
        let originalStyle = clip.textStyle ?? TextStyle()
        let originalAnchorX = Self.textAnchorX(
            centerX: clip.transform.centerX,
            width: clip.transform.width,
            alignment: originalStyle.alignment
        )
        if let sample = look.sampleText, clip.captionGroupId == nil {
            clip.textContent = sample
        }
        if let patch = look.stylePatch, patch.hasAnyField {
            var style = clip.textStyle ?? TextStyle()
            Self.applyTextStylePatch(patch, to: &style)
            clip.textStyle = style
        }
        if look.stylePatch?.affectsLayout == true || look.sampleText != nil {
            _ = editor.fitTextClipToContentIfNeeded(&clip, canvasW: canvasW, canvasH: canvasH)
        }
        let updatedStyle = clip.textStyle ?? TextStyle()
        if look.stylePatch?.alignment != nil || look.transform?.x != nil {
            clip.transform.centerX = Self.textCenterX(
                anchorX: look.transform?.x ?? originalAnchorX,
                width: clip.transform.width,
                alignment: updatedStyle.alignment
            )
        }
        if let y = look.transform?.y { clip.transform.centerY = y }
        if let rotation = look.transform?.rotation { clip.transform.rotation = rotation }
        if let rotationX = look.transform?.rotationX { clip.transform.rotationX = rotationX }
        if let rotationY = look.transform?.rotationY { clip.transform.rotationY = rotationY }
        if let animation = look.animation { clip.textAnimation = animation }
    }

    private func previewItem(_ mediaRef: String, editor: EditorViewModel, clipId: String?) async throws -> PreviewItem {
        let asset = try asset(mediaRef, editor: editor)
        guard let kind = MCPPreviewStore.Kind.from(asset.type) else {
            throw ToolError(
                "show_preview cannot play \(asset.type.rawValue) assets. Use inspect_media or inspect_timeline."
            )
        }
        let url = asset.url
        let mime = MCPPreviewApp.mimeType(for: url, type: asset.type)
        let generation = PreviewGeneration(asset)
        let exists = await Task.detached(priority: .utility) {
            FileManager.default.isReadableFile(atPath: url.path)
        }.value
        if !exists, !asset.isGenerating, asset.generationStatus == .none {
            throw ToolError("Media file not on disk: \(url.lastPathComponent)")
        }
        let handle = MCPPreviewStore.AssetHandle(
            mediaRef: mediaRef,
            fileURL: exists ? url : nil,
            mimeType: mime,
            kind: kind,
            width: asset.sourceWidth,
            height: asset.sourceHeight,
            durationSeconds: asset.duration > 0 ? asset.duration : nil,
            status: generation?.status,
            failure: {
                if case .failed(let message) = asset.generationStatus { return message }
                return nil
            }()
        )
        let token = await MCPPreviewStore.shared.upsert(handle)
        let previewURL = exists ? MCPPreviewApp.previewURL(token: token) : nil
        return PreviewItem(
            mediaRef: mediaRef,
            name: asset.name,
            kind: kind,
            url: previewURL,
            eventsURL: MCPPreviewApp.eventsURL(token: token),
            width: asset.sourceWidth,
            height: asset.sourceHeight,
            durationSeconds: asset.duration > 0 ? asset.duration : nil,
            generation: generation,
            canUpscale: asset.type == .video || asset.type == .image,
            clipId: clipId
        )
    }

    private func previewResult(_ payload: [String: Any], structured: Value) throws -> ToolResult {
        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) else {
            throw ToolError("Failed to encode preview")
        }
        return ToolResult(
            content: [.text(json)],
            isError: false,
            structuredContent: structured,
            mcpMeta: MCPPreviewApp.toolMeta
        )
    }
}

private struct LookPreview {
    let stylePatch: ParsedTextStylePatch?
    let transform: ParsedTextTransform?
    let animation: TextAnimation?
    let sampleText: String?
    let raw: [String: Any]
    var captionGroupIds: [String]

    var json: [String: Any] {
        var obj = raw
        obj["mode"] = captionGroupIds.isEmpty ? "sample" : "restyle"
        if !captionGroupIds.isEmpty { obj["captionGroupIds"] = captionGroupIds }
        return obj
    }

    var value: Value {
        var obj: [String: Value] = [
            "mode": .string(captionGroupIds.isEmpty ? "sample" : "restyle"),
        ]
        if let sampleText { obj["sampleText"] = .string(sampleText) }
        if !captionGroupIds.isEmpty {
            obj["captionGroupIds"] = .array(captionGroupIds.map { .string($0) })
        }
        return .object(obj)
    }

    var applyCalls: [[String: Any]] {
        if captionGroupIds.isEmpty {
            var arguments: [String: Any] = [:]
            if let style = raw["style"] { arguments["style"] = style }
            if let transform = raw["transform"] { arguments["transform"] = transform }
            if let animation = raw["animation"] { arguments["animation"] = animation }
            if let highlight = raw["highlightColor"] { arguments["highlightColor"] = highlight }
            return [["name": "add_captions", "arguments": arguments]]
        }
        return captionGroupIds.map { gid in
            var arguments: [String: Any] = ["captionGroupId": gid]
            if let style = raw["style"] { arguments["style"] = style }
            if let transform = raw["transform"] { arguments["transform"] = transform }
            if let animation = raw["animation"] { arguments["animation"] = animation }
            if let highlight = raw["highlightColor"] { arguments["highlightColor"] = highlight }
            return ["name": "update_text", "arguments": arguments]
        }
    }

    var applyCallValues: [Value] {
        applyCalls.map { call in
            .object([
                "name": .string(call["name"] as? String ?? ""),
                "arguments": jsonValue(call["arguments"] ?? [:]),
            ])
        }
    }

    private func jsonValue(_ any: Any) -> Value {
        switch any {
        case let object as [String: Any]:
            .object(object.mapValues { jsonValue($0) })
        case let array as [Any]:
            .array(array.map { jsonValue($0) })
        case let string as String:
            .string(string)
        case let bool as Bool:
            .bool(bool)
        case let int as Int:
            .int(int)
        case let double as Double:
            .double(double)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                .bool(number.boolValue)
            } else if Double(number.intValue) == number.doubleValue {
                .int(number.intValue)
            } else {
                .double(number.doubleValue)
            }
        default:
            .null
        }
    }
}

private struct PreviewGeneration {
    let prompt: String?
    let model: String
    let modelId: String
    let aspectRatio: String?
    let status: String?

    @MainActor
    init?(_ asset: MediaAsset) {
        guard let input = asset.generationInput else { return nil }
        let prompt = input.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        self.prompt = prompt.isEmpty ? nil : String(prompt.prefix(160))
        self.modelId = input.model
        self.model = ModelRegistry.displayName(for: input.model)
        self.aspectRatio = input.aspectRatio.isEmpty ? nil : input.aspectRatio
        switch asset.generationStatus {
        case .none: status = nil
        default: status = asset.generationStatus.serialized
        }
    }

    var json: [String: Any] {
        var obj: [String: Any] = [
            "model": model,
            "modelId": modelId,
        ]
        if let prompt { obj["prompt"] = prompt }
        if let aspectRatio { obj["aspectRatio"] = aspectRatio }
        if let status { obj["status"] = status }
        return obj
    }

    var value: Value {
        var obj: [String: Value] = [
            "model": .string(model),
            "modelId": .string(modelId),
        ]
        if let prompt { obj["prompt"] = .string(prompt) }
        if let aspectRatio { obj["aspectRatio"] = .string(aspectRatio) }
        if let status { obj["status"] = .string(status) }
        return .object(obj)
    }
}

private struct PreviewItem {
    let mediaRef: String
    let name: String
    let kind: MCPPreviewStore.Kind
    let url: String?
    let eventsURL: String
    let width: Int?
    let height: Int?
    let durationSeconds: Double?
    let generation: PreviewGeneration?
    let canUpscale: Bool
    let clipId: String?

    var json: [String: Any] {
        var obj: [String: Any] = [
            "mediaRef": mediaRef,
            "name": name,
            "type": kind.rawValue,
            "eventsUrl": eventsURL,
            "canPlace": true,
            "canUpscale": canUpscale,
            "canOpen": true,
        ]
        if let url { obj["url"] = url }
        if let width { obj["width"] = width }
        if let height { obj["height"] = height }
        if let durationSeconds { obj["durationSeconds"] = durationSeconds }
        if let generation { obj["generation"] = generation.json }
        if let clipId {
            obj["clipId"] = clipId
            obj["canKeep"] = true
        }
        return obj
    }

    var value: Value {
        var obj: [String: Value] = [
            "mediaRef": .string(mediaRef),
            "name": .string(name),
            "type": .string(kind.rawValue),
            "eventsUrl": .string(eventsURL),
            "canPlace": .bool(true),
            "canUpscale": .bool(canUpscale),
            "canOpen": .bool(true),
        ]
        if let url { obj["url"] = .string(url) }
        if let width { obj["width"] = .int(width) }
        if let height { obj["height"] = .int(height) }
        if let durationSeconds { obj["durationSeconds"] = .double(durationSeconds) }
        if let generation { obj["generation"] = generation.value }
        if let clipId {
            obj["clipId"] = .string(clipId)
            obj["canKeep"] = .bool(true)
        }
        return .object(obj)
    }
}
