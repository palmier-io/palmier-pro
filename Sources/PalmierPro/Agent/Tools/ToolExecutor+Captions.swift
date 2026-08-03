import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let addCaptionsAllowedKeys: Set<String> = Set([
        "style", "transform", "censorProfanity", "language", "animation", "highlightColor", "maxWords", "trackIndex",
        "maximumGapSeconds",
    ])

    func addCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addCaptionsAllowedKeys, path: "add_captions")

        let stylePatch = try parseTextStylePatch(args, path: "add_captions")
        var style = TextStyle.caption
        if let stylePatch { Self.applyTextStylePatch(stylePatch, to: &style) }

        var center = AppTheme.Caption.defaultCenter
        if let t = args["transform"] as? [String: Any] {
            try validateUnknownKeys(t, allowed: ["centerX", "centerY"], path: "add_captions.transform")
            if let x = t.double("centerX") { center.x = CGFloat(x) }
            if let y = t.double("centerY") { center.y = CGFloat(y) }
        }

        let animation = try parseTextAnimation(preset: args.string("animation"), highlightColor: args.string("highlightColor"), path: "add_captions") ?? TextAnimation()

        var maxWords: Int?
        if let n = args.int("maxWords") {
            guard n >= 1 else { throw ToolError("add_captions: maxWords must be >= 1 (got \(n))") }
            maxWords = n
        }

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
        request.censorProfanity = args.bool("censorProfanity") ?? false
        request.locale = context.preferredLocale
        request.maxWords = maxWords
        request.gapSettings = gapSettings
        request.animation = animation

        try await Self.validateCloudTranscriptionAccess(for: request, in: editor)

        let snapshot = timelineSnapshot(editor)
        let ids = try await editor.generateCaptions(for: request, applying: { mutation in
            editor.undo.perform("Generate Captions (Agent)", mutation)
        })
        guard !ids.isEmpty else { throw ToolError("No speech detected to caption.") }
        return mutationResult(editor, since: snapshot)
    }
}
