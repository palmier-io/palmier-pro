import Foundation

/// A named caption look: font, size, weight, case, colour, outline/scrim/box,
/// position, plus optional animation. Stored as a value; captions carry the
/// resolved style at generation time, so `update_text` can restyle later.
struct CaptionStyle: Equatable, Identifiable, Sendable, Hashable {
    enum Group: String, Sendable, CaseIterable {
        case loud
        case onBox
        case calm
    }

    enum Background: String, Sendable {
        case none
        case soft
        case box
    }

    var id: String
    var displayName: String
    var intent: String
    var group: Group
    var fontName: String
    var sizeRatio: Double
    var isBold: Bool
    var tracking: Double
    var fontCase: TextStyle.FontCase
    var alignment: TextStyle.Alignment
    var color: TextStyle.RGBA
    var outlineWidth: Double
    var outlineColor: TextStyle.RGBA
    var background: Background
    var shadowEnabled: Bool
    var centerYRatio: Double
    var animationPreset: TextAnimation.Preset
    var highlight: TextStyle.RGBA?

    struct Resolved {
        var style: TextStyle
        var animation: TextAnimation
        var center: (x: Double, y: Double)
    }

    /// Resolves against a canvas height with clamped, finite values.
    func resolved(canvasHeight: Int) -> Resolved {
        let height = Double(max(1, canvasHeight))
        var style = TextStyle()
        style.fontName = fontName
        style.fontSize = max(12, min(300, sizeRatio * height))
        style.isBold = isBold
        style.tracking = tracking
        style.fontCase = fontCase
        style.alignment = alignment
        style.color = color
        if outlineWidth > 0 {
            style.border = TextStyle.Outline(enabled: true, color: outlineColor, width: max(1, outlineWidth * style.fontSize))
        }
        switch background {
        case .none:
            break
        case .soft:
            let pad = style.fontSize * 0.35
            style.background = TextStyle.Background(
                enabled: true, color: TextStyle.RGBA(r: 0, g: 0, b: 0, a: 0.42),
                paddingX: pad, paddingY: pad * 0.6,
                cornerRadius: pad * 0.35, offsetX: 0, offsetY: 0)
        case .box:
            let padX = style.fontSize * 0.55
            let padY = style.fontSize * 0.30
            style.background = TextStyle.Background(
                enabled: true, color: TextStyle.RGBA(r: 0.08, g: 0.08, b: 0.09, a: 0.88),
                paddingX: padX, paddingY: padY,
                cornerRadius: padY * 0.5, offsetX: 0, offsetY: 0)
        }
        if shadowEnabled {
            style.shadow = TextStyle.Shadow(enabled: true, color: TextStyle.RGBA(r: 0, g: 0, b: 0, a: 0.55),
                                            offsetX: 0, offsetY: max(1, style.fontSize * 0.06), blur: max(2, style.fontSize * 0.12))
        }
        let animation = TextAnimation(preset: animationPreset, highlight: highlight)
        return Resolved(style: style, animation: animation, center: (0.5, min(0.95, max(0.05, centerYRatio))))
    }
}

enum CaptionStyles {
    private static func c(_ r: Double, _ g: Double, _ b: Double) -> TextStyle.RGBA {
        TextStyle.RGBA(r: r, g: g, b: b, a: 1)
    }

    private static let yellow = TextStyle.RGBA(r: 1, g: 0.85, b: 0, a: 1)
    private static let white = TextStyle.RGBA(r: 1, g: 1, b: 1, a: 1)
    private static let ink = TextStyle.RGBA(r: 0.08, g: 0.08, b: 0.09, a: 1)
    private static let cyan = TextStyle.RGBA(r: 0.25, g: 0.9, b: 1, a: 1)

    static let all: [CaptionStyle] = [
        // MARK: Loud
        CaptionStyle(id: "bold-pop", displayName: "Bold Pop", intent: "Heavy uppercase Anton with a hard edge. Short-form hooks that must win in one second.",
                     group: .loud, fontName: "Anton", sizeRatio: 0.058, isBold: false, tracking: 0.3,
                     fontCase: .uppercase, alignment: .center, color: white, outlineWidth: 0.05,
                     outlineColor: ink, background: .none, shadowEnabled: true, centerYRatio: 0.8,
                     animationPreset: .popIn, highlight: nil),
        CaptionStyle(id: "karaoke", displayName: "Karaoke", intent: "Word-by-word sliding reveal with a yellow highlight. Lyrics and sing-along energy.",
                     group: .loud, fontName: "Poppins", sizeRatio: 0.05, isBold: true, tracking: 0,
                     fontCase: .uppercase, alignment: .center, color: white, outlineWidth: 0.045,
                     outlineColor: ink, background: .none, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .wordSlide, highlight: yellow),
        CaptionStyle(id: "typewriter", displayName: "Typewriter", intent: "Monospaced typewriter entrance over a soft scrim. Documentary titles, names, readouts.",
                     group: .loud, fontName: "GeistMono", sizeRatio: 0.042, isBold: false, tracking: 0,
                     fontCase: .mixed, alignment: .center, color: white, outlineWidth: 0,
                     outlineColor: ink, background: .soft, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .typewriter, highlight: nil),
        CaptionStyle(id: "one-word", displayName: "One Word", intent: "Large word-reveal captions for single-word punches. Keep lines to one accent word.",
                     group: .loud, fontName: "Poppins", sizeRatio: 0.07, isBold: true, tracking: 0.5,
                     fontCase: .uppercase, alignment: .center, color: white, outlineWidth: 0.05,
                     outlineColor: ink, background: .none, shadowEnabled: true, centerYRatio: 0.78,
                     animationPreset: .wordReveal, highlight: nil),
        CaptionStyle(id: "neon", displayName: "Neon", intent: "Shrikhand display face with a cyan glow edge. Loud, playful, nighttime/funk moods.",
                     group: .loud, fontName: "Shrikhand", sizeRatio: 0.052, isBold: false, tracking: 0,
                     fontCase: .mixed, alignment: .center, color: cyan, outlineWidth: 0.03,
                     outlineColor: ink, background: .none, shadowEnabled: true, centerYRatio: 0.8,
                     animationPreset: .popIn, highlight: nil),
        CaptionStyle(id: "3d-pop", displayName: "3D Pop", intent: "Cinematic deep-shadow title look. Trailer and reveal moments.",
                     group: .loud, fontName: "BebasNeue", sizeRatio: 0.062, isBold: false, tracking: 1,
                     fontCase: .uppercase, alignment: .center, color: white, outlineWidth: 0.02,
                     outlineColor: ink, background: .none, shadowEnabled: true, centerYRatio: 0.78,
                     animationPreset: .popIn, highlight: nil),
        CaptionStyle(id: "gradient", displayName: "Gradient", intent: "Bright caption on a dark box for daylight footage. Readable over bright scenes.",
                     group: .loud, fontName: "BasementGrotesque", sizeRatio: 0.05, isBold: true, tracking: 0.5,
                     fontCase: .uppercase, alignment: .center, color: c(0.95, 0.95, 1), outlineWidth: 0,
                     outlineColor: ink, background: .box, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .slideUp, highlight: nil),
        CaptionStyle(id: "beast", displayName: "Beast", intent: "Maximum-impact condensed poster caps. Hooks, titles, covers.",
                     group: .loud, fontName: "Anton", sizeRatio: 0.07, isBold: false, tracking: 0.5,
                     fontCase: .uppercase, alignment: .center, color: white, outlineWidth: 0.055,
                     outlineColor: ink, background: .none, shadowEnabled: true, centerYRatio: 0.76,
                     animationPreset: .popIn, highlight: nil),
        CaptionStyle(id: "comic", displayName: "Comic", intent: "Permanent-marker hand-drawn caps. Humor, youth, lo-fi energy.",
                     group: .loud, fontName: "PermanentMarker", sizeRatio: 0.048, isBold: false, tracking: 0,
                     fontCase: .mixed, alignment: .center, color: white, outlineWidth: 0.04,
                     outlineColor: ink, background: .none, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .popIn, highlight: nil),
        CaptionStyle(id: "terminal", displayName: "Terminal", intent: "Monospaced low-effects captions with a hard edge. Tech and CLI aesthetics.",
                     group: .loud, fontName: "GeistMono", sizeRatio: 0.04, isBold: true, tracking: 0,
                     fontCase: .mixed, alignment: .center, color: c(0.55, 1, 0.6), outlineWidth: 0.03,
                     outlineColor: ink, background: .none, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .typewriter, highlight: nil),
        CaptionStyle(id: "sticker", displayName: "Sticker", intent: "Marker caps with thick outline and pop entrance. Social, meme, youth captions.",
                     group: .loud, fontName: "PermanentMarker", sizeRatio: 0.052, isBold: false, tracking: 0,
                     fontCase: .uppercase, alignment: .center, color: yellow, outlineWidth: 0.065,
                     outlineColor: ink, background: .none, shadowEnabled: true, centerYRatio: 0.8,
                     animationPreset: .popIn, highlight: nil),

        // MARK: On a box
        CaptionStyle(id: "boxed", displayName: "Boxed", intent: "Solid dark box behind tall Bebas caps. Broadcast/news lower-thirds.",
                     group: .onBox, fontName: "BebasNeue", sizeRatio: 0.058, isBold: false, tracking: 1.5,
                     fontCase: .uppercase, alignment: .center, color: white, outlineWidth: 0,
                     outlineColor: ink, background: .box, shadowEnabled: false, centerYRatio: 0.78,
                     animationPreset: .slideUp, highlight: nil),
        CaptionStyle(id: "subtitle", displayName: "Subtitle", intent: "Production-standard subtitle: white on soft scrim, Inter bold. Default legibility.",
                     group: .onBox, fontName: "Inter", sizeRatio: 0.048, isBold: true, tracking: 0,
                     fontCase: .mixed, alignment: .center, color: white, outlineWidth: 0,
                     outlineColor: ink, background: .soft, shadowEnabled: false, centerYRatio: 0.82,
                     animationPreset: .none, highlight: nil),
        CaptionStyle(id: "soft-glass", displayName: "Soft Glass", intent: "Rounded translucent box, gentle edges. Travel and lifestyle footage.",
                     group: .onBox, fontName: "BasementGrotesque", sizeRatio: 0.045, isBold: true, tracking: 0,
                     fontCase: .mixed, alignment: .center, color: white, outlineWidth: 0,
                     outlineColor: ink, background: .box, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .slideUp, highlight: nil),
        CaptionStyle(id: "magazine", displayName: "Magazine", intent: "Serif Playfair uppercases on a box. Editorial headlines and titles.",
                     group: .onBox, fontName: "PlayfairDisplay", sizeRatio: 0.052, isBold: false, tracking: 2,
                     fontCase: .uppercase, alignment: .center, color: white, outlineWidth: 0,
                     outlineColor: ink, background: .box, shadowEnabled: false, centerYRatio: 0.76,
                     animationPreset: .none, highlight: nil),
        CaptionStyle(id: "paper", displayName: "Paper", intent: "Dark serif type on a pale box. Documentary titles over busy footage.",
                     group: .onBox, fontName: "PlayfairDisplay", sizeRatio: 0.046, isBold: false, tracking: 0.5,
                     fontCase: .mixed, alignment: .center, color: ink, outlineWidth: 0,
                     outlineColor: ink, background: .none, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .none, highlight: nil),
        CaptionStyle(id: "label", displayName: "Label", intent: "Wide-tracked Geist caps, minimal box. Chapter and section labels.",
                     group: .onBox, fontName: "Geist", sizeRatio: 0.032, isBold: true, tracking: 5,
                     fontCase: .uppercase, alignment: .center, color: white, outlineWidth: 0.04,
                     outlineColor: ink, background: .soft, shadowEnabled: false, centerYRatio: 0.7,
                     animationPreset: .none, highlight: nil),
        CaptionStyle(id: "notebook", displayName: "Notebook", intent: "Caveat handwriting on a box. Vlog and diary energy.",
                     group: .onBox, fontName: "Caveat", sizeRatio: 0.058, isBold: false, tracking: 0,
                     fontCase: .mixed, alignment: .center, color: ink, outlineWidth: 0,
                     outlineColor: ink, background: .none, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .typewriter, highlight: nil),
        CaptionStyle(id: "highlighter", displayName: "Highlighter", intent: "Per-word highlight block with dark edge. Emphasis and key-word moments.",
                     group: .onBox, fontName: "Poppins", sizeRatio: 0.048, isBold: true, tracking: 0,
                     fontCase: .uppercase, alignment: .center, color: white, outlineWidth: 0.04,
                     outlineColor: ink, background: .soft, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .highlightBlock, highlight: yellow),
        CaptionStyle(id: "highlight", displayName: "Highlight", intent: "Word-by-word highlight pops. Karatoke-adjacent emphasis with hard edge.",
                     group: .onBox, fontName: "SpaceGrotesk", sizeRatio: 0.046, isBold: true, tracking: 0.5,
                     fontCase: .uppercase, alignment: .center, color: white, outlineWidth: 0.04,
                     outlineColor: ink, background: .soft, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .highlightPop, highlight: yellow),

        // MARK: Calm
        CaptionStyle(id: "clean", displayName: "Clean", intent: "Quiet white on soft scrim, no animation. Interviews that must not distract.",
                     group: .calm, fontName: "Inter", sizeRatio: 0.042, isBold: false, tracking: 0,
                     fontCase: .mixed, alignment: .center, color: white, outlineWidth: 0,
                     outlineColor: ink, background: .soft, shadowEnabled: false, centerYRatio: 0.84,
                     animationPreset: .none, highlight: nil),
        CaptionStyle(id: "minimal", displayName: "Minimal", intent: "Small plain caps, thin case. Intertitles and diagrams.",
                     group: .calm, fontName: "Geist", sizeRatio: 0.032, isBold: false, tracking: 2,
                     fontCase: .uppercase, alignment: .center, color: c(0.92, 0.92, 0.94), outlineWidth: 0,
                     outlineColor: ink, background: .none, shadowEnabled: false, centerYRatio: 0.84,
                     animationPreset: .none, highlight: nil),
        CaptionStyle(id: "handwritten", displayName: "Handwritten", intent: "Caveat handwriting with dark edge. Personal notes overced footage.",
                     group: .calm, fontName: "Caveat", sizeRatio: 0.052, isBold: false, tracking: 0,
                     fontCase: .mixed, alignment: .center, color: white, outlineWidth: 0.035,
                     outlineColor: ink, background: .none, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .none, highlight: nil),
        CaptionStyle(id: "serif", displayName: "Serif", intent: "Playfair serif, mixed case. Period pieces and ceremony.",
                     group: .calm, fontName: "PlayfairDisplay", sizeRatio: 0.042, isBold: false, tracking: 0.5,
                     fontCase: .mixed, alignment: .center, color: white, outlineWidth: 0.03,
                     outlineColor: ink, background: .none, shadowEnabled: false, centerYRatio: 0.82,
                     animationPreset: .none, highlight: nil),
        CaptionStyle(id: "quiet", displayName: "Quiet", intent: "Small muted scrim caps. Background dialogue, lowest prominence.",
                     group: .calm, fontName: "Inter", sizeRatio: 0.034, isBold: false, tracking: 0,
                     fontCase: .mixed, alignment: .center, color: c(0.85, 0.85, 0.87), outlineWidth: 0,
                     outlineColor: ink, background: .soft, shadowEnabled: false, centerYRatio: 0.86,
                     animationPreset: .none, highlight: nil),
        CaptionStyle(id: "editorial", displayName: "Editorial", intent: "DMSans tracked uppercase, thin edge. Essays and explainers.",
                     group: .calm, fontName: "DMSans", sizeRatio: 0.034, isBold: true, tracking: 3,
                     fontCase: .uppercase, alignment: .center, color: white, outlineWidth: 0.035,
                     outlineColor: ink, background: .soft, shadowEnabled: false, centerYRatio: 0.82,
                     animationPreset: .none, highlight: nil),
        CaptionStyle(id: "script-mix", displayName: "Script Mix", intent: "Caveat with entrance animation. Captions that feel written live.",
                     group: .calm, fontName: "Caveat", sizeRatio: 0.05, isBold: false, tracking: 0,
                     fontCase: .mixed, alignment: .center, color: white, outlineWidth: 0.04,
                     outlineColor: ink, background: .none, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .popIn, highlight: nil),
        CaptionStyle(id: "cinema", displayName: "Cinema", intent: "Bebas caps, thin outline. Movie-trailer lower-thirds.",
                     group: .calm, fontName: "BebasNeue", sizeRatio: 0.044, isBold: false, tracking: 2.5,
                     fontCase: .uppercase, alignment: .center, color: white, outlineWidth: 0.03,
                     outlineColor: ink, background: .soft, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .none, highlight: nil),
        CaptionStyle(id: "lyric", displayName: "Lyric", intent: "Poppins lyric style, slide entrance. Music performances.",
                     group: .calm, fontName: "Poppins", sizeRatio: 0.046, isBold: true, tracking: 0,
                     fontCase: .mixed, alignment: .center, color: white, outlineWidth: 0.04,
                     outlineColor: ink, background: .soft, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .slideUp, highlight: nil),
        CaptionStyle(id: "duo", displayName: "Duo", intent: "SpaceGrotesk two-tone box caps. YouTube and podcast cuts.",
                     group: .calm, fontName: "SpaceGrotesk", sizeRatio: 0.04, isBold: true, tracking: 1,
                     fontCase: .uppercase, alignment: .center, color: white, outlineWidth: 0,
                     outlineColor: ink, background: .box, shadowEnabled: false, centerYRatio: 0.8,
                     animationPreset: .none, highlight: nil),
        CaptionStyle(id: "retro", displayName: "Retro", intent: "Playfair with dark edge, no animation. Vintage and archival captions.",
                     group: .calm, fontName: "PlayfairDisplay", sizeRatio: 0.04, isBold: false, tracking: 1,
                     fontCase: .mixed, alignment: .center, color: c(0.95, 0.92, 0.85), outlineWidth: 0.03,
                     outlineColor: ink, background: .none, shadowEnabled: false, centerYRatio: 0.82,
                     animationPreset: .none, highlight: nil),
    ]

    /// Fallback when no selection exists.
    static let defaultStyle: CaptionStyle = all[12] // subtitle

    static func preset(id: String) -> CaptionStyle? {
        all.first { $0.id == id }
    }

    static var availableIds: String {
        all.map(\.id).joined(separator: ", ")
    }
}
