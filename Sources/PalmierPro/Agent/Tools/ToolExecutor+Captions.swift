import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let addCaptionsAllowedKeys: Set<String> = Set([
        "clipIds", "centerX", "centerY", "textCase", "censorProfanity", "language", "animation", "highlightColor", "maxCharacters", "maxWords", "transcriptionProvider",
    ]).union(agentTextStylePatchAllowedKeys)

    private static let alignCaptionsAllowedKeys: Set<String> = [
        "captionGroupId", "captionClipIds", "sourceClipIds", "language",
    ]

    func addCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addCaptionsAllowedKeys, path: "add_captions")

        let clipIds = (args["clipIds"] as? [Any])?.compactMap { $0 as? String } ?? []

        var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        _ = Self.applyTextStylePatch(try parseTextStylePatch(args, path: "add_captions"), to: &style)

        let locale = try await Self.parseLocale(args, path: "add_captions")

        var center = AppTheme.Caption.defaultCenter
        if let x = args.double("centerX") { center.x = CGFloat(x) }
        if let y = args.double("centerY") { center.y = CGFloat(y) }

        var textCase: EditorViewModel.CaptionCase = .auto
        if let raw = args.string("textCase") {
            guard let parsed = EditorViewModel.CaptionCase(rawValue: raw) else {
                throw ToolError("add_captions: textCase must be auto, upper, or lower (got \(raw))")
            }
            textCase = parsed
        }

        let maxCharacters: Int?
        if args.keys.contains("maxCharacters") {
            guard let value = args.int("maxCharacters") else {
                throw ToolError("add_captions: maxCharacters must be an integer")
            }
            guard (1...120).contains(value) else {
                throw ToolError("add_captions: maxCharacters must be between 1 and 120")
            }
            maxCharacters = value
        } else {
            maxCharacters = nil
        }

        let animation = try parseTextAnimation(preset: args.string("animation"), highlightColor: args.string("highlightColor"), path: "add_captions") ?? TextAnimation()

        var maxWords: Int?
        if let n = args.int("maxWords") {
            guard n >= 1 else { throw ToolError("add_captions: maxWords must be >= 1 (got \(n))") }
            maxWords = n
        }

        let transcriptionProvider: CaptionTranscriptionProvider
        if let raw = args.string("transcriptionProvider") {
            guard let parsed = CaptionTranscriptionProvider(rawValue: raw) else {
                throw ToolError("add_captions: transcriptionProvider must be local or volcengine (got \(raw))")
            }
            transcriptionProvider = parsed
        } else {
            transcriptionProvider = CaptionTranscriptionProviderPreference.stored
        }

        let request = EditorViewModel.CaptionRequest(
            sourceClipIds: clipIds,
            autoDetect: clipIds.isEmpty,
            style: style,
            center: center,
            textCase: textCase,
            censorProfanity: args.bool("censorProfanity") ?? false,
            locale: locale,
            maxCharacters: maxCharacters,
            maxWords: maxWords,
            animation: animation,
            transcriptionProvider: transcriptionProvider
        )

        let ids = try await editor.generateCaptions(for: request)
        guard !ids.isEmpty else { throw ToolError("No speech detected to caption.") }
        let suffix = animation.isActive ? " (\(animation.preset.rawValue))" : ""
        return .ok("Added \(ids.count) caption\(ids.count == 1 ? "" : "s")\(suffix).")
    }

    func alignCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.alignCaptionsAllowedKeys, path: "align_captions")
        guard VolcengineSpeechAvailability.canExposeCaptionAlignment else {
            throw ToolError("align_captions: Volcengine Speech API key is not configured.")
        }
        let sourceClipIds = (args["sourceClipIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        let captionClipIds = (args["captionClipIds"] as? [Any])?.compactMap { $0 as? String } ?? []
        let locale = try await Self.parseLocale(args, path: "align_captions")
        let ids = try await editor.alignCaptionsWithVolcengine(
            sourceClipIds: sourceClipIds,
            captionGroupId: args.string("captionGroupId"),
            captionClipIds: captionClipIds,
            locale: locale
        )
        guard !ids.isEmpty else { throw ToolError("align_captions: no captions were aligned.") }
        return .ok("Aligned \(ids.count) caption\(ids.count == 1 ? "" : "s").")
    }
}
