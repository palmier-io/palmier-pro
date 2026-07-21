import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let addCaptionsAllowedKeys: Set<String> = Set([
        "style", "transform", "censorProfanity", "language", "animation", "highlightColor", "maxWords", "fillerPolicy",
    ])

    func addCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addCaptionsAllowedKeys, path: "add_captions")

        let profile = CaptionStyleStore.resolve(projectPackageURL: editor.projectURL).profile

        // Explicit style/maxWords/transform params always win FIELD-WISE; the profile fills every
        // field the caller left unspecified (a partial style must not discard the whole profile).
        let stylePatch = try parseTextStylePatch(args, path: "add_captions")
        var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        Self.applyProfileTypography(profile.typography, to: &style)
        if let stylePatch {
            Self.applyTextStylePatch(stylePatch, to: &style)
        }

        var center = AppTheme.Caption.defaultCenter
        if let position = profile.typography.position { center = CGPoint(x: position.x, y: position.y) }
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
        } else if let profileMax = profile.typography.maxWords, profileMax >= 1 {
            maxWords = profileMax
        }

        let fillerPolicy = try parseFillerPolicy(args.string("fillerPolicy"), path: "add_captions")

        let context = try await transcriptionContext(args, path: "add_captions") {
            await editor.captionCloudCreditCost(for: .init(autoDetect: true, provider: .cloud))
        }
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
            textCase: .auto,
            censorProfanity: args.bool("censorProfanity") ?? false,
            locale: context.preferredLocale,
            maxWords: maxWords,
            provider: provider,
            animation: animation,
            fillerProfile: fillerPolicy == .removeAlways ? profile : nil,
            dropRemoveAlwaysFillers: fillerPolicy == .removeAlways
        )

        try await Self.validateCloudTranscriptionAccess(for: request, in: editor)

        let snapshot = timelineSnapshot(editor)
        let ids = try await editor.generateCaptions(for: request, applying: { mutation in
            editor.undo.perform("Generate Captions (Agent)", mutation)
        })
        guard !ids.isEmpty else { throw ToolError("No speech detected to caption.") }
        return mutationResult(editor, since: snapshot)
    }

    private enum FillerPolicyMode: String { case off, removeAlways }

    private func parseFillerPolicy(_ raw: String?, path: String) throws -> FillerPolicyMode {
        guard let raw else { return .off }
        guard let mode = FillerPolicyMode(rawValue: raw) else {
            throw ToolError("\(path): invalid fillerPolicy '\(raw)'. Expected 'off' or 'removeAlways'.")
        }
        return mode
    }

    /// Fill caption typography defaults from a resolved profile. Only non-nil profile keys override.
    static func applyProfileTypography(_ typography: CaptionStyleProfile.Typography, to style: inout TextStyle) {
        if let fontName = typography.fontName { style.fontName = fontName }
        if let fontSize = typography.fontSize { style.fontSize = fontSize }
        if let hex = typography.color, let color = TextStyle.RGBA(hex: hex) { style.color = color }
        if let outline = typography.outline { style.border.enabled = outline }
        if let shadow = typography.shadow { style.shadow.enabled = shadow }
    }
}
