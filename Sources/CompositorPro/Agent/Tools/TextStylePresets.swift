import Foundation

/// A named type style, expressed as a complete `TextStyle` plus the placement it implies.
///
/// The point is consistency. Picking font, weight, size, outline and position per clip is how
/// titles end up looking placed rather than designed: each one is defensible and none of them
/// belong together. A preset fixes the decisions that should not vary, and leaves the rest open.
///
/// Sizes are relative to the canvas height, so the same style reads the same on a 1080p landscape
/// frame and a vertical export. Nothing here implies timing or position on the timeline.
struct TextStylePreset: Equatable, Identifiable, Sendable {
    var id: String
    /// When to reach for it. Part of the tool contract, not localized.
    var intent: String
    /// Font size as a fraction of canvas height.
    var sizeRatio: Double
    /// Where the block sits, as a fraction of canvas height. Only meaningful for anchored styles.
    var centerYRatio: Double
    var fontName: String
    var isBold: Bool
    var tracking: Double
    var fontCase: TextStyle.FontCase
    var alignment: TextStyle.Alignment
    /// A dark edge behind light words, scaled to the type, so bright footage cannot swallow it.
    var outlineRatio: Double
    var scrim: Bool

    static func == (lhs: TextStylePreset, rhs: TextStylePreset) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Resolves against a real canvas, clamping so a hostile size cannot produce unreadable type.
    func resolved(canvasHeight: Int) -> TextStyle {
        let height = Double(max(1, canvasHeight))
        var style = TextStyle()
        style.fontName = fontName
        style.fontSize = max(12, min(300, sizeRatio * height))
        style.isBold = isBold
        style.tracking = tracking
        style.fontCase = fontCase
        style.alignment = alignment
        style.color = TextStyle.RGBA(r: 1, g: 1, b: 1, a: 1)
        if outlineRatio > 0 {
            style.border = TextStyle.Outline(
                enabled: true,
                color: TextStyle.RGBA(r: 0, g: 0, b: 0, a: 0.85),
                width: max(1, outlineRatio * style.fontSize)
            )
        }
        if scrim {
            // A soft darkening behind the words. Padding is proportional so the scrim hugs the
            // type rather than sitting in a box.
            let pad = style.fontSize * 0.35
            style.background = TextStyle.Background(
                enabled: true,
                color: TextStyle.RGBA(r: 0, g: 0, b: 0, a: 0.42),
                paddingX: pad, paddingY: pad * 0.6,
                cornerRadius: pad * 0.35, offsetX: 0, offsetY: 0
            )
        }
        return style
    }

    var center: (x: Double, y: Double) { (0.5, centerYRatio) }
}

@MainActor
enum TextStylePresets {
    /// Every font referenced here is bundled, so a preset cannot resolve to a missing face.
    static let all: [TextStylePreset] = [
        TextStylePreset(
            id: "title",
            intent: "The main title of a piece. Large, tight, centred low in frame so it clears the "
                + "subject's face. Anton is a condensed poster face; use it once per piece, not per shot.",
            sizeRatio: 0.11, centerYRatio: 0.72,
            fontName: "Anton", isBold: false, tracking: 0.5,
            fontCase: .uppercase, alignment: .center, outlineRatio: 0, scrim: false
        ),
        TextStylePreset(
            id: "lowerThird",
            intent: "A name or role over an interview. Small, set left, sitting low with the scrim "
                + "behind it. Use DM Sans for interviews and Geist for anything corporate.",
            sizeRatio: 0.042, centerYRatio: 0.82,
            fontName: "DMSans", isBold: true, tracking: 0,
            fontCase: .mixed, alignment: .left, outlineRatio: 0, scrim: true
        ),
        TextStylePreset(
            id: "caption",
            intent: "Burned-in captions. Maximum legibility over anything: white on a scrim, "
                + "centred, and no outline because the scrim does that job.",
            sizeRatio: 0.048, centerYRatio: 0.86,
            fontName: "Inter", isBold: true, tracking: 0,
            fontCase: .mixed, alignment: .center, outlineRatio: 0, scrim: true
        ),
        TextStylePreset(
            id: "kicker",
            intent: "A short label above the main title — a section name, a category, a chapter. "
                + "Small, wide-tracked, uppercase. Never competes with the title it introduces.",
            sizeRatio: 0.03, centerYRatio: 0.58,
            fontName: "Geist", isBold: true, tracking: 6,
            fontCase: .uppercase, alignment: .center, outlineRatio: 0.045, scrim: false
        ),
        TextStylePreset(
            id: "credit",
            intent: "End-credit lines. Small, centred, with a thin dark edge so a name stays "
                + "readable over a bright frame without a scrim box interrupting the roll.",
            sizeRatio: 0.036, centerYRatio: 0.5,
            fontName: "Inter", isBold: false, tracking: 1.5,
            fontCase: .uppercase, alignment: .center, outlineRatio: 0.05, scrim: false
        ),
        TextStylePreset(
            id: "elegant",
            intent: "Titles with some ceremony — a documentary title card, a period piece. A "
                + "serif, not bold, with generous tracking.",
            sizeRatio: 0.075, centerYRatio: 0.7,
            fontName: "PlayfairDisplay", isBold: false, tracking: 3,
            fontCase: .uppercase, alignment: .center, outlineRatio: 0.035, scrim: false
        ),
        TextStylePreset(
            id: "technical",
            intent: "Data, timecode, frame numbers and anything monospaced, so digits do not "
                + "shift as they change. Always the same face as any other technical readout.",
            sizeRatio: 0.034, centerYRatio: 0.5,
            fontName: "GeistMono", isBold: false, tracking: 0,
            fontCase: .mixed, alignment: .left, outlineRatio: 0, scrim: false
        ),
        TextStylePreset(
            id: "social",
            intent: "Short-form hook text. Heavy, all caps, high contrast with a hard edge, for "
                + "a caption that has to survive being watched on a phone.",
            sizeRatio: 0.085, centerYRatio: 0.5,
            fontName: "Poppins", isBold: true, tracking: 0,
            fontCase: .uppercase, alignment: .center, outlineRatio: 0.055, scrim: false
        ),
    ]

    static func preset(id: String) -> TextStylePreset? {
        all.first { $0.id == id }
    }
}