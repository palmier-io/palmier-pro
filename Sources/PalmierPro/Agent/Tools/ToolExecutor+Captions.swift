import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let addCaptionsAllowedKeys: Set<String> = Set([
        "transform", "textCase", "censorProfanity", "language", "animation", "highlightColor", "maxWords",
    ]).union(agentTextStylePatchAllowedKeys)

    func addCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addCaptionsAllowedKeys, path: "add_captions")

        var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        _ = Self.applyTextStylePatch(try parseTextStylePatch(args, path: "add_captions"), to: &style)

        var center = AppTheme.Caption.defaultCenter
        if let t = args["transform"] as? [String: Any] {
            try validateUnknownKeys(t, allowed: ["centerX", "centerY"], path: "add_captions.transform")
            if let x = t.double("centerX") { center.x = CGFloat(x) }
            if let y = t.double("centerY") { center.y = CGFloat(y) }
        }

        var textCase: EditorViewModel.CaptionCase = .auto
        if let raw = args.string("textCase") {
            guard let parsed = EditorViewModel.CaptionCase(rawValue: raw) else {
                throw ToolError("add_captions: textCase must be auto, upper, or lower (got \(raw))")
            }
            textCase = parsed
        }

        let animation = try parseTextAnimation(preset: args.string("animation"), highlightColor: args.string("highlightColor"), path: "add_captions") ?? TextAnimation()

        var maxWords: Int?
        if let n = args.int("maxWords") {
            guard n >= 1 else { throw ToolError("add_captions: maxWords must be >= 1 (got \(n))") }
            maxWords = n
        }

        let context = try await transcriptionContext(args, path: "add_captions")
        let provider = context.provider
        if provider == .cloud {
            if args.bool("censorProfanity") == true {
                throw ToolError("add_captions: censorProfanity is only available with local transcription.")
            }
        }

        let request = EditorViewModel.CaptionRequest(
            sourceClipIds: [],
            autoDetect: true,
            style: style,
            center: center,
            textCase: textCase,
            censorProfanity: args.bool("censorProfanity") ?? false,
            locale: context.preferredLocale,
            maxWords: maxWords,
            provider: provider,
            animation: animation
        )

        try await Self.validateCloudTranscriptionAccess(for: request, in: editor)

        let snapshot = timelineSnapshot(editor)
        let ids = try await editor.generateCaptions(for: request)
        guard !ids.isEmpty else { throw ToolError("No speech detected to caption.") }
        return mutationResult(editor, since: snapshot)
    }
}
