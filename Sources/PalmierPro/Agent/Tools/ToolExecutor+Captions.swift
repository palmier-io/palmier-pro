import CoreGraphics
import Foundation

extension ToolExecutor {
    private static let addCaptionsAllowedKeys: Set<String> = Set([
        "style", "transform", "censorProfanity", "language", "animation", "highlightColor", "granularity", "maxWords", "fillerPolicy", "segmentation",
    ])

    /// Resolve the shared `segmentation` param (add_captions / resync_captions). An explicit param
    /// always wins; otherwise the resolved profile's typography.segmentation is honored; otherwise
    /// the built-in natural default. An unknown profile value (hand-edited) falls back to natural.
    func parseSegmentation(_ raw: String?, profileDefault: String? = nil, path: String) throws -> CaptionBuilder.Segmentation {
        if let raw {
            guard let mode = CaptionBuilder.Segmentation(rawValue: raw) else {
                throw ToolError("\(path): invalid segmentation '\(raw)'. Expected 'natural' or 'fixedChars'.")
            }
            return mode
        }
        if let profileDefault, let mode = CaptionBuilder.Segmentation(rawValue: profileDefault) { return mode }
        return .default
    }

    func addCaptions(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.addCaptionsAllowedKeys, path: "add_captions")

        let profile = CaptionStyleStore.resolve(projectPackageURL: editor.projectURL).profile

        // Explicit style/maxWords/transform params always win; the profile fills only when absent.
        let stylePatch = try parseTextStylePatch(args, path: "add_captions")
        var style = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        if let stylePatch {
            Self.applyTextStylePatch(stylePatch, to: &style)
        } else {
            Self.applyProfileTypography(profile.typography, to: &style)
        }

        var center = AppTheme.Caption.defaultCenter
        if let t = args["transform"] as? [String: Any] {
            try validateUnknownKeys(t, allowed: ["centerX", "centerY"], path: "add_captions.transform")
            if let x = t.double("centerX") { center.x = CGFloat(x) }
            if let y = t.double("centerY") { center.y = CGFloat(y) }
        } else if let position = profile.typography.position {
            center = CGPoint(x: position.x, y: position.y)
        }

        let animation = try parseTextAnimation(preset: args.string("animation"), highlightColor: args.string("highlightColor"), granularity: args.string("granularity"), path: "add_captions") ?? TextAnimation()

        var maxWords: Int?
        if let n = args.int("maxWords") {
            guard n >= 1 else { throw ToolError("add_captions: maxWords must be >= 1 (got \(n))") }
            maxWords = n
        } else if let profileMax = profile.typography.maxWords, profileMax >= 1 {
            maxWords = profileMax
        }

        let fillerPolicy = try parseFillerPolicy(args.string("fillerPolicy"), path: "add_captions")
        let segmentation = try parseSegmentation(args.string("segmentation"), profileDefault: profile.typography.segmentation, path: "add_captions")

        let context = try await transcriptionContext(args, path: "add_captions", preference: editor.transcriptionPreference) {
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
            dropRemoveAlwaysFillers: fillerPolicy == .removeAlways,
            punctuation: CaptionText.PunctuationPolicy(profileValue: profile.typography.punctuation),
            segmentation: segmentation
        )

        try await Self.validateCloudTranscriptionAccess(for: request, in: editor)

        let snapshot = timelineSnapshot(editor)
        let ids = try await editor.generateCaptions(for: request, applying: { mutation in
            editor.undo.perform("Generate Captions (Agent)", mutation)
        })
        guard !ids.isEmpty else { throw ToolError("No speech detected to caption.") }

        let extra: [String: Any] = [
            "transcriptionSource": provider.rawValue,
            "transcriptionModel": Self.resolvedModelLabel(models: editor.lastTranscriptionModels, provider: provider),
            "resolved": Self.captionResolved(
                segmentation: segmentation,
                maxWords: maxWords,
                fillerPolicy: fillerPolicy,
                typographyFromParams: stylePatch != nil
            ),
        ]
        let notes = context.fellBackToLocal ? [TranscriptionToolContext.lowAccuracyNotice] : []
        return mutationResult(editor, since: snapshot, extra: extra, notes: notes)
    }

    /// Echo what add_captions actually resolved, so the agent sees whether its params or the profile won.
    static func captionResolved(
        segmentation: CaptionBuilder.Segmentation,
        maxWords: Int?,
        fillerPolicy: FillerPolicyMode,
        typographyFromParams: Bool
    ) -> [String: Any] {
        var resolved: [String: Any] = [
            "segmentation": segmentation.rawValue,
            "fillerPolicy": fillerPolicy.rawValue,
            "typographyFrom": typographyFromParams ? "params" : "profile",
        ]
        if let maxWords { resolved["maxWords"] = maxWords }
        return resolved
    }

    enum FillerPolicyMode: String { case off, removeAlways }

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
