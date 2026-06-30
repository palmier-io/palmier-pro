import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let addCaptionsAllowedKeys: Set<String> = Set([
        "clipIds", "centerX", "centerY", "textCase", "censorProfanity", "language", "animation", "highlightColor", "maxWords",
    ]).union(agentTextStylePatchAllowedKeys)

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

        let animation = try parseTextAnimation(preset: args.string("animation"), highlightColor: args.string("highlightColor"), path: "add_captions") ?? TextAnimation()

        var maxWords: Int?
        if let n = args.int("maxWords") {
            guard n >= 1 else { throw ToolError("add_captions: maxWords must be >= 1 (got \(n))") }
            maxWords = n
        }

        let request = EditorViewModel.CaptionRequest(
            sourceClipIds: clipIds,
            autoDetect: clipIds.isEmpty,
            style: style,
            center: center,
            textCase: textCase,
            censorProfanity: args.bool("censorProfanity") ?? false,
            locale: locale,
            maxWords: maxWords,
            animation: animation
        )

        let ids = try await editor.generateCaptions(for: request)
        guard !ids.isEmpty else { throw ToolError("No speech detected to caption.") }
        let suffix = animation.isActive ? " (\(animation.preset.rawValue))" : ""
        return .ok("Added \(ids.count) caption\(ids.count == 1 ? "" : "s")\(suffix).")
    }
}
