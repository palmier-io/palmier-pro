import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let addCaptionsAllowedKeys: Set<String> = Set([
        "style", "transform", "censorProfanity", "language", "animation", "highlightColor", "maxWords",
        "maxCharacters", "trackIndex", "maximumGapSeconds", "subtitleMediaRef", "platform",
        "captionStyle",
    ])

    func addCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addCaptionsAllowedKeys, path: "add_captions")

        if args.keys.contains("subtitleMediaRef") {
            guard let subtitleMediaRef = args.string("subtitleMediaRef"), !subtitleMediaRef.isEmpty else {
                throw ToolError("add_captions: subtitleMediaRef must be a non-empty media asset id string.")
            }
            // A subtitle file has no position of its own, so `platform` is allowed: it decides
            // where the captions sit rather than overriding anything the file supplied.
            let combined = Set(args.keys).subtracting(["subtitleMediaRef", "platform"])
            guard combined.isEmpty else {
                throw ToolError(
                    "add_captions: subtitleMediaRef uses the file's text, timing, and default styling as-is; "
                    + "remove \(combined.sorted().joined(separator: ", "))."
                )
            }
            let platform = try deliveryPlatform(args.string("platform"), path: "add_captions.platform")
            return try await addCaptions(
                fromSubtitle: subtitleMediaRef, editor: editor, platform: platform
            )
        }

        var presetStyle: CaptionStyle.Resolved?
        if args["captionStyle"] != nil {
            guard let styleId = args.string("captionStyle"), !styleId.isEmpty,
                  let preset = CaptionStyles.preset(id: styleId) else {
                throw ToolError("add_captions: captionStyle '\(args.string("captionStyle") ?? "")' is not a known style. Choose one of: \(CaptionStyles.availableIds).")
            }
            let stylingKeys = Set(args.keys).intersection(["style", "animation", "highlightColor"])
            guard stylingKeys.isEmpty else {
                throw ToolError("add_captions: captionStyle encodes style and animation together; remove \(stylingKeys.sorted().joined(separator: ", ")).")
            }
            if let transform = try parseTextTransform(args["transform"], path: "add_captions.transform"),
               transform.x != nil || transform.rotation != nil || transform.rotationX != nil || transform.rotationY != nil {
                throw ToolError("add_captions: captionStyle positions the captions; remove transform x/rotation.")
            }
            presetStyle = preset.resolved(canvasHeight: editor.timeline.height)
        }

        let stylePatch = try parseTextStylePatch(args, path: "add_captions")
        var style = presetStyle?.style ?? TextStyle.caption
        if let stylePatch { Self.applyTextStylePatch(stylePatch, to: &style) }

        let platform = try deliveryPlatform(args.string("platform"), path: "add_captions.platform")
        let transform = try parseTextTransform(args["transform"], path: "add_captions.transform")
        // A caller-supplied position is honoured, but never left underneath the platform's
        // own interface.
        let placement = platform.defaultCaptionPlacement().clamped(into: platform.coveredArea)
        var center = presetStyle.map { CGPoint(x: CGFloat($0.center.x), y: CGFloat($0.center.y)) }
            ?? CGPoint(x: CGFloat(placement.centerX), y: CGFloat(placement.centerY))
        if let x = transform?.x { center.x = CGFloat(x) }
        if let y = transform?.y { center.y = CGFloat(y) }
        let clamped = DeliveryPlatform.CaptionPlacement(
            centerX: Double(center.x), centerY: Double(center.y), maxWidth: placement.maxWidth
        ).clamped(into: platform.coveredArea)
        center = CGPoint(x: CGFloat(clamped.centerX), y: CGFloat(clamped.centerY))

        let animation: TextAnimation
        if let presetStyle {
            animation = presetStyle.animation
        } else {
            animation = try parseTextAnimation(preset: args.string("animation"), highlightColor: args.string("highlightColor"), path: "add_captions") ?? TextAnimation()
        }

        let maxWords = try captionLimit("maxWords", from: args)
        let maxCharacters = try captionLimit("maxCharacters", from: args)

        let gapSettings: CaptionGapSettings
        if let rawMaximumGap = args["maximumGapSeconds"] {
            guard !isJSONBoolean(rawMaximumGap),
                  rawMaximumGap is NSNumber || rawMaximumGap is Double || rawMaximumGap is Int,
                  let maximumGapSeconds = args.double("maximumGapSeconds"),
                  let parsed = CaptionGapSettings(maximumGapSeconds: maximumGapSeconds) else {
                throw ToolError(
                    "add_captions: maximumGapSeconds must be a finite number from "
                    + "\(CaptionGapSettings.maximumGapRange.lowerBound) through "
                    + "\(CaptionGapSettings.maximumGapRange.upperBound)."
                )
            }
            gapSettings = parsed
        } else {
            gapSettings = .default
        }

        let scope = try resolveTranscriptionScope(editor, args, path: "add_captions")
        let cloudRequest = scope.captionRequest(in: editor, provider: .cloud)
        let context = try await transcriptionContext(args, path: "add_captions") {
            await editor.captionCloudCreditCost(for: cloudRequest)
        }
        let provider = context.provider
        if provider == .cloud {
            if args.bool("censorProfanity") == true {
                throw ToolError("add_captions: censorProfanity is only available with local transcription.")
            }
        }

        var request = scope.captionRequest(in: editor, provider: provider)
        request.style = style
        request.center = center
        request.platform = platform
        request.censorProfanity = args.bool("censorProfanity") ?? false
        request.locale = context.preferredLocale
        request.maxWords = maxWords
        request.maxCharacters = maxCharacters
        request.gapSettings = gapSettings
        request.animation = animation

        try await Self.validateCloudTranscriptionAccess(for: request, in: editor)

        let snapshot = timelineSnapshot(editor)
        let ids = try await editor.generateCaptions(for: request, applying: { mutation in
            try editor.undo.perform("Generate Captions (Agent)") {
                let ids = try mutation()
                if transform?.x != nil || transform?.rotation != nil
                    || transform?.rotationX != nil || transform?.rotationY != nil {
                    editor.commitClipProperties(clipIds: ids, actionName: "Transform Captions (Agent)") { clip in
                        if let x = transform?.x {
                            clip.transform.centerX = Self.textCenterX(
                                anchorX: x,
                                width: clip.transform.width,
                                alignment: style.alignment
                            )
                        }
                        if let rotation = transform?.rotation {
                            clip.transform.rotation = rotation
                        }
                        if let rotationX = transform?.rotationX {
                            clip.transform.rotationX = rotationX
                        }
                        if let rotationY = transform?.rotationY {
                            clip.transform.rotationY = rotationY
                        }
                    }
                }
                return ids
            }
        })
        guard !ids.isEmpty else { throw ToolError("No speech detected to caption.") }
        return mutationResult(editor, since: snapshot)
    }

    private func addCaptions(
        fromSubtitle mediaRef: String, editor: EditorViewModel, platform: DeliveryPlatform
    ) async throws -> ToolResult {
        guard let asset = editor.mediaAssets.first(where: { $0.id == mediaRef }) else {
            throw ToolError("add_captions: media asset not found: \(mediaRef)")
        }
        guard asset.type == .subtitle else {
            throw ToolError("add_captions: '\(mediaRef)' is \(asset.type.rawValue), not a subtitle file. Omit subtitleMediaRef to caption spoken audio.")
        }
        guard let url = editor.mediaResolver.resolveURL(for: asset.id) else {
            throw ToolError("add_captions: the subtitle file for '\(mediaRef)' is offline.")
        }
        let snapshot = timelineSnapshot(editor)
        do {
            let ids = try await editor.importCaptions(from: url, platform: platform)
            guard !ids.isEmpty else { throw ToolError("The subtitle file contains no captions.") }
            return mutationResult(editor, since: snapshot)
        } catch let error as SubtitleFileParser.ParseError {
            throw ToolError("add_captions: \(error.localizedDescription)")
        }
    }

    private func captionLimit(_ key: String, from args: [String: Any]) throws -> Int? {
        guard args.keys.contains(key) else { return nil }
        guard let value = exactJSONInt(args[key]), value >= 1 else {
            throw ToolError("add_captions: \(key) must be an integer >= 1.")
        }
        return value
    }
}
