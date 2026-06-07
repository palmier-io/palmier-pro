import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let addCaptionsAllowedKeys: Set<String> = [
        "clipIds", "fontSize", "color", "centerX", "centerY", "textCase", "censorProfanity",
    ]

    func addCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addCaptionsAllowedKeys, path: "add_captions")

        let clipIds = (args["clipIds"] as? [Any])?.compactMap { $0 as? String } ?? []

        var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        if let s = args.double("fontSize") { style.fontSize = s }
        if let c = try parseColorHex(args.string("color"), path: "add_captions") { style.color = c }

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

        let request = EditorViewModel.CaptionRequest(
            sourceClipIds: clipIds,
            autoDetect: clipIds.isEmpty,
            style: style,
            center: center,
            textCase: textCase,
            censorProfanity: args.bool("censorProfanity") ?? false
        )

        let ids = try await editor.generateCaptions(for: request)
        guard !ids.isEmpty else { throw ToolError("No speech detected to caption.") }
        return .ok("Added \(ids.count) caption\(ids.count == 1 ? "" : "s").")
    }
}
