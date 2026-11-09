import CoreGraphics
import Foundation

/// Target social video format and aspect ratio classification for caption templates.
enum SocialCaptionFormat: String, CaseIterable, Codable, Sendable {
    case vertical916 = "vertical_9_16"
    case horizontal169 = "horizontal_16_9"
    case all = "all"

    var displayName: String {
        switch self {
        case .vertical916: return "Reels & TikTok (9:16)"
        case .horizontal169: return "YouTube (16:9)"
        case .all: return "All Formats"
        }
    }

    var badgeLabel: String {
        switch self {
        case .vertical916: return "9:16"
        case .horizontal169: return "16:9"
        case .all: return "All"
        }
    }

    var aspectRatio: String {
        switch self {
        case .vertical916: return "9:16"
        case .horizontal169: return "16:9"
        case .all: return "Adaptive"
        }
    }

    var targetPlatforms: [String] {
        switch self {
        case .vertical916: return ["instagramReels", "tiktokShorts", "youtubeShorts"]
        case .horizontal169: return ["youtube"]
        case .all: return ["instagramReels", "tiktokShorts", "youtubeShorts", "youtube"]
        }
    }

    /// Safe vertical center ratio clear of platform interfaces (descriptions, action rails, transport bars).
    var safeCenterYRatio: Double {
        switch self {
        case .vertical916: return 0.72 // Clears TikTok/Reels bottom 20% description & audio rail
        case .horizontal169: return 0.84 // Standard lower-third, clear of YouTube controls
        case .all: return 0.80
        }
    }

    static func resolve(_ input: String?) -> SocialCaptionFormat {
        guard let raw = input?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .all
        }
        if raw.contains("reel") || raw.contains("tiktok") || raw.contains("short") || raw.contains("vert") || raw.contains("9:16") || raw.contains("9_16") {
            return .vertical916
        }
        if raw.contains("youtube") || raw.contains("horiz") || raw.contains("16:9") || raw.contains("16_9") || raw.contains("landscape") {
            return .horizontal169
        }
        return .all
    }
}

/// Visual preview metadata for a caption template thumbnail.
struct CaptionTemplateThumbnail: Sendable, Codable, Equatable {
    var sampleText: String
    var badgeLabel: String
    var aspectRatio: String
    var colorHex: String
    var outlineColorHex: String?
    var backgroundHex: String?
    var visualSummary: String
}

/// A structured caption template configured and optimized for specific social video formats.
struct CaptionTemplate: Identifiable, Sendable, Codable, Equatable {
    var id: String
    var displayName: String
    var format: SocialCaptionFormat
    var formatLabel: String
    var targetPlatforms: [String]
    var fontName: String
    var fontSizeRatio: Double
    var isBold: Bool
    var fontCase: String
    var alignment: String
    var colorHex: String
    var outlineWidth: Double
    var outlineColorHex: String
    var background: String
    var shadow: Bool
    var animationPreset: String
    var highlightColorHex: String?
    var centerYRatio: Double
    var intent: String
    var previewThumbnail: CaptionTemplateThumbnail

    var stylePreset: CaptionStyle? {
        CaptionStyles.preset(id: id)
    }
}

/// Receipt returned when a caption template is applied across project captions.
struct CaptionTemplateApplyReceipt: Codable, Sendable, Equatable {
    var templateId: String
    var templateName: String
    var format: String
    var formatLabel: String
    var appliedClipCount: Int
    var updatedClipIds: [String]
    var trackIndices: [Int]
    var centerYRatio: Double
    var undoable: Bool
}

/// Errors raised during caption template selection or application.
enum CaptionTemplateError: Error, LocalizedError, Equatable {
    case unknownTemplate(String, available: String)
    case noCaptionsFound

    var errorDescription: String? {
        switch self {
        case .unknownTemplate(let id, let available):
            return "Caption template '\(id)' is not known. Available templates: \(available)."
        case .noCaptionsFound:
            return "No text or caption clips found on the timeline to apply the template to."
        }
    }
}

/// Library of caption templates organized and tagged by social media format (Reels, TikTok, YouTube Shorts, YouTube).
enum CaptionTemplateLibrary {

    private static func hex(_ rgba: TextStyle.RGBA) -> String {
        let r = max(0, min(255, Int((rgba.r * 255).rounded())))
        let g = max(0, min(255, Int((rgba.g * 255).rounded())))
        let b = max(0, min(255, Int((rgba.b * 255).rounded())))
        return String(format: "#%02X%02X%02X", r, g, b)
    }

    /// Curated set of templates mapped from CaptionStyles with social format tags and safe zone positions.
    static let all: [CaptionTemplate] = [
        // MARK: - Vertical (9:16) · Reels, TikTok, YouTube Shorts
        makeTemplate(
            id: "bold-pop",
            format: .vertical916,
            formatLabel: "Reels / TikTok / Shorts (9:16)",
            customCenterY: 0.72,
            sample: "BOLD POP",
            summary: "Anton uppercase with black outline and popIn animation"
        ),
        makeTemplate(
            id: "karaoke",
            format: .vertical916,
            formatLabel: "Reels / TikTok / Shorts (9:16)",
            customCenterY: 0.72,
            sample: "KARAOKE SLIDE",
            summary: "Poppins uppercase with yellow word-by-word slide highlight"
        ),
        makeTemplate(
            id: "one-word",
            format: .vertical916,
            formatLabel: "Reels / TikTok / Shorts (9:16)",
            customCenterY: 0.70,
            sample: "PUNCH",
            summary: "Large single-word pop reveal for short-form hooks"
        ),
        makeTemplate(
            id: "neon",
            format: .vertical916,
            formatLabel: "Reels / TikTok / Shorts (9:16)",
            customCenterY: 0.72,
            sample: "NEON GLOW",
            summary: "Shrikhand cyan glow display with pop entrance"
        ),
        makeTemplate(
            id: "beast",
            format: .vertical916,
            formatLabel: "Reels / TikTok / Shorts (9:16)",
            customCenterY: 0.70,
            sample: "BEAST POSTER",
            summary: "Maximum-impact condensed Anton poster caps"
        ),
        makeTemplate(
            id: "comic",
            format: .vertical916,
            formatLabel: "Reels / TikTok / Shorts (9:16)",
            customCenterY: 0.72,
            sample: "COMIC POP",
            summary: "PermanentMarker hand-drawn caps for humor and youth"
        ),
        makeTemplate(
            id: "terminal",
            format: .vertical916,
            formatLabel: "Reels / TikTok / Shorts (9:16)",
            customCenterY: 0.72,
            sample: "$ TECH_CLI",
            summary: "GeistMono neon green monospace with typewriter entrance"
        ),
        makeTemplate(
            id: "sticker",
            format: .vertical916,
            formatLabel: "Reels / TikTok / Shorts (9:16)",
            customCenterY: 0.72,
            sample: "STICKER MEME",
            summary: "Yellow marker caps with heavy outline and pop entrance"
        ),
        makeTemplate(
            id: "highlighter",
            format: .vertical916,
            formatLabel: "Reels / TikTok / Shorts (9:16)",
            customCenterY: 0.72,
            sample: "HIGHLIGHT BLOCK",
            summary: "Poppins caps with active yellow highlight box"
        ),
        makeTemplate(
            id: "highlight",
            format: .vertical916,
            formatLabel: "Reels / TikTok / Shorts (9:16)",
            customCenterY: 0.72,
            sample: "HIGHLIGHT POP",
            summary: "SpaceGrotesk word-by-word highlight pop"
        ),
        makeTemplate(
            id: "gradient",
            format: .vertical916,
            formatLabel: "Reels / TikTok / Shorts (9:16)",
            customCenterY: 0.74,
            sample: "GRADIENT BOX",
            summary: "Bright caption on dark box readable over daylight scenes"
        ),
        makeTemplate(
            id: "3d-pop",
            format: .vertical916,
            formatLabel: "Reels / TikTok / Shorts (9:16)",
            customCenterY: 0.72,
            sample: "3D CINEMATIC",
            summary: "BebasNeue uppercase with deep shadow for trailer moments"
        ),
        makeTemplate(
            id: "boxed",
            format: .vertical916,
            formatLabel: "Reels / TikTok / Shorts (9:16)",
            customCenterY: 0.74,
            sample: "BREAKING NEWS",
            summary: "Solid dark box behind tall Bebas caps"
        ),

        // MARK: - Horizontal (16:9) · YouTube
        makeTemplate(
            id: "subtitle",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "Standard Subtitle",
            summary: "Production-standard white on soft scrim, Inter bold"
        ),
        makeTemplate(
            id: "clean",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "Clean Dialogue",
            summary: "Quiet white on soft scrim, no distraction for interviews"
        ),
        makeTemplate(
            id: "minimal",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "MINIMAL INTERTITLE",
            summary: "Small plain Geist caps for diagrams and intertitles"
        ),
        makeTemplate(
            id: "magazine",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.82,
            sample: "EDITORIAL TITLE",
            summary: "PlayfairDisplay serif uppercase on dark box"
        ),
        makeTemplate(
            id: "paper",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "Documentary Paper",
            summary: "Dark serif type on pale paper background"
        ),
        makeTemplate(
            id: "label",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.80,
            sample: "CHAPTER 01",
            summary: "Wide-tracked Geist caps on soft box for section labels"
        ),
        makeTemplate(
            id: "soft-glass",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "Lifestyle Subtitle",
            summary: "Rounded translucent glass box for travel and lifestyle"
        ),
        makeTemplate(
            id: "editorial",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "ESSAY & EXPLAINER",
            summary: "DMSans tracked uppercase with thin edge for explainers"
        ),
        makeTemplate(
            id: "cinema",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "CINEMA LOWER-THIRD",
            summary: "Bebas caps with thin outline for movie trailers"
        ),
        makeTemplate(
            id: "duo",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "PODCAST CUT",
            summary: "SpaceGrotesk two-tone box caps for podcast clips"
        ),
        makeTemplate(
            id: "serif",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "Period Drama",
            summary: "PlayfairDisplay serif mixed case for history and drama"
        ),
        makeTemplate(
            id: "retro",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "Vintage Archival",
            summary: "Warm off-white serif with dark edge for vintage footage"
        ),
        makeTemplate(
            id: "typewriter",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "Log entry 042",
            summary: "Monospaced typewriter entrance over soft scrim"
        ),
        makeTemplate(
            id: "lyric",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "Music performance",
            summary: "Poppins lyric style with smooth slide entrance"
        ),
        makeTemplate(
            id: "quiet",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.86,
            sample: "background dialogue",
            summary: "Small muted scrim caps for lowest prominence dialogue"
        ),
        makeTemplate(
            id: "notebook",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "Vlog Diary Entry",
            summary: "Caveat handwriting on pale box for vlogs"
        ),
        makeTemplate(
            id: "handwritten",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "Personal Notes",
            summary: "Caveat handwriting with subtle edge for personal essays"
        ),
        makeTemplate(
            id: "script-mix",
            format: .horizontal169,
            formatLabel: "YouTube (16:9)",
            customCenterY: 0.84,
            sample: "Live Written Note",
            summary: "Caveat handwritten font with pop entrance"
        ),
    ]

    private static func makeTemplate(
        id: String,
        format: SocialCaptionFormat,
        formatLabel: String,
        customCenterY: Double,
        sample: String,
        summary: String
    ) -> CaptionTemplate {
        let preset = CaptionStyles.preset(id: id) ?? CaptionStyles.defaultStyle
        let colorH = hex(preset.color)
        let outlineH = hex(preset.outlineColor)
        let highlightH = preset.highlight.map(hex)

        let bgHex: String?
        switch preset.background {
        case .none: bgHex = nil
        case .soft: bgHex = "#0000006B"
        case .box: bgHex = "#141417E0"
        }

        let thumbnail = CaptionTemplateThumbnail(
            sampleText: sample,
            badgeLabel: format.badgeLabel,
            aspectRatio: format.aspectRatio,
            colorHex: colorH,
            outlineColorHex: preset.outlineWidth > 0 ? outlineH : nil,
            backgroundHex: bgHex,
            visualSummary: summary
        )

        return CaptionTemplate(
            id: preset.id,
            displayName: preset.displayName,
            format: format,
            formatLabel: formatLabel,
            targetPlatforms: format.targetPlatforms,
            fontName: preset.fontName,
            fontSizeRatio: preset.sizeRatio,
            isBold: preset.isBold,
            fontCase: preset.fontCase.label.lowercased(),
            alignment: preset.alignment.rawValue,
            colorHex: colorH,
            outlineWidth: preset.outlineWidth,
            outlineColorHex: outlineH,
            background: preset.background.rawValue,
            shadow: preset.shadowEnabled,
            animationPreset: preset.animationPreset.rawValue,
            highlightColorHex: highlightH,
            centerYRatio: customCenterY,
            intent: preset.intent,
            previewThumbnail: thumbnail
        )
    }

    /// Returns templates matching the given format filter ("all", "vertical", "horizontal", "reels", "tiktok", "youtube", etc.).
    static func list(format: String? = nil) -> [CaptionTemplate] {
        let resolved = SocialCaptionFormat.resolve(format)
        switch resolved {
        case .all:
            return all
        case .vertical916:
            return all.filter { $0.format == .vertical916 }
        case .horizontal169:
            return all.filter { $0.format == .horizontal169 }
        }
    }

    /// Retrieves an individual template by ID.
    static func template(id: String) -> CaptionTemplate? {
        all.first { $0.id == id }
    }

    /// Comma-separated list of available template IDs.
    static func availableIds(for format: String? = nil) -> String {
        list(format: format).map(\.id).joined(separator: ", ")
    }
}

