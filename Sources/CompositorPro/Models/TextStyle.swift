import AppKit
import CoreText
import SwiftUI

struct TextStyle: Codable, Sendable, Equatable, Hashable {
    static let axisScaleRange = 0.1...10.0

    var fontName: String = "Helvetica"
    var fontSize: Double = 96
    var fontScale: Double = 1.0
    var widthScale: Double = 1.0
    var heightScale: Double = 1.0
    var tracking: Double = 0
    var lineSpacing: Double = 0
    var fontCase: FontCase = .mixed
    var isBold: Bool = false
    var isItalic: Bool = false
    var isUnderlined: Bool = false
    var isStruckThrough: Bool = false
    var isOverlined: Bool = false
    var color: RGBA = RGBA()
    var alignment: Alignment = .center
    var blur: Double = 0
    var shadow: Shadow = Shadow()
    var background: Background = Background()
    var border: Outline = Outline()

    enum Alignment: String, Codable, Sendable, CaseIterable, Hashable {
        case left
        case center
        case right
    }

    enum FontCase: String, Codable, Sendable, CaseIterable, Hashable {
        case mixed
        case uppercase
        case lowercase

        var label: String {
            switch self {
            case .mixed: L10n.key("Mixed")
            case .uppercase: L10n.key("UPPERCASE")
            case .lowercase: L10n.key("lowercase")
            }
        }

        func apply(to text: String) -> String {
            switch self {
            case .mixed: text
            case .uppercase: text.uppercased()
            case .lowercase: text.lowercased()
            }
        }
    }

    struct RGBA: Codable, Sendable, Equatable, Hashable {
        var r: Double = 1
        var g: Double = 1
        var b: Double = 1
        var a: Double = 1
    }

    struct Shadow: Codable, Sendable, Equatable, Hashable {
        var enabled: Bool = false
        /// Alpha doubles as opacity; layer.shadowOpacity stays at 1.
        var color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6)
        /// Canvas points; scaled at render time.
        var offsetX: Double = 0
        var offsetY: Double = -2
        var blur: Double = 6
    }

    struct Outline: Codable, Sendable, Equatable, Hashable {
        var enabled: Bool = false
        var color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 1)
        /// Width in reference-canvas points.
        var width: Double = 4

        init(enabled: Bool = false, color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 1), width: Double = 4) {
            self.enabled = enabled
            self.color = color
            self.width = width
        }

        private enum CodingKeys: String, CodingKey { case enabled, color, width }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? false,
                color: (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA(r: 0, g: 0, b: 0, a: 1),
                width: (try? c.decode(Double.self, forKey: .width)) ?? 4
            )
        }
    }

    struct Background: Codable, Sendable, Equatable, Hashable {
        var enabled: Bool = false
        var color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6)
        var paddingX: Double = 0
        var paddingY: Double = 0
        var cornerRadius: Double = 0
        var offsetX: Double = 0
        var offsetY: Double = 0
        var outlineColor: RGBA = RGBA(r: 0, g: 0, b: 0, a: 1)
        var outlineWidth: Double = 0

        init(
            enabled: Bool = false,
            color: RGBA = RGBA(r: 0, g: 0, b: 0, a: 0.6),
            paddingX: Double = 0,
            paddingY: Double = 0,
            cornerRadius: Double = 0,
            offsetX: Double = 0,
            offsetY: Double = 0,
            outlineColor: RGBA = RGBA(r: 0, g: 0, b: 0, a: 1),
            outlineWidth: Double = 0
        ) {
            self.enabled = enabled
            self.color = color
            self.paddingX = paddingX
            self.paddingY = paddingY
            self.cornerRadius = cornerRadius
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.outlineColor = outlineColor
            self.outlineWidth = outlineWidth
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, color, paddingX, paddingY, cornerRadius, offsetX, offsetY, outlineColor, outlineWidth
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                enabled: (try? c.decode(Bool.self, forKey: .enabled)) ?? false,
                color: (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA(r: 0, g: 0, b: 0, a: 0.6),
                paddingX: (try? c.decode(Double.self, forKey: .paddingX)) ?? 0,
                paddingY: (try? c.decode(Double.self, forKey: .paddingY)) ?? 0,
                cornerRadius: (try? c.decode(Double.self, forKey: .cornerRadius)) ?? 0,
                offsetX: (try? c.decode(Double.self, forKey: .offsetX)) ?? 0,
                offsetY: (try? c.decode(Double.self, forKey: .offsetY)) ?? 0,
                outlineColor: (try? c.decode(RGBA.self, forKey: .outlineColor)) ?? RGBA(r: 0, g: 0, b: 0, a: 1),
                outlineWidth: (try? c.decode(Double.self, forKey: .outlineWidth)) ?? 0
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, fontScale, widthScale, heightScale, tracking, lineSpacing, fontCase
        case isBold, isItalic, isUnderlined, isStruckThrough, isOverlined
        case color, alignment, blur, shadow, background, border
    }
}

extension TextStyle {
    static var caption: TextStyle { TextStyle(fontSize: AppTheme.Caption.defaultFontSize) }
}

extension TextStyle {
    /// Missing-key-tolerant decode — older files pick up defaults for fields added later.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = TextStyle()
        let fontName = (try? c.decode(String.self, forKey: .fontName)) ?? defaults.fontName
        let fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? defaults.fontSize
        let inferredTraits = Self.symbolicTraits(fontName: fontName, size: CGFloat(fontSize))
        self.init(
            fontName: fontName,
            fontSize: fontSize,
            fontScale: (try? c.decode(Double.self, forKey: .fontScale)) ?? defaults.fontScale,
            widthScale: (try? c.decode(Double.self, forKey: .widthScale)) ?? defaults.widthScale,
            heightScale: (try? c.decode(Double.self, forKey: .heightScale)) ?? defaults.heightScale,
            tracking: (try? c.decode(Double.self, forKey: .tracking)) ?? defaults.tracking,
            lineSpacing: (try? c.decode(Double.self, forKey: .lineSpacing)) ?? defaults.lineSpacing,
            fontCase: (try? c.decode(FontCase.self, forKey: .fontCase)) ?? defaults.fontCase,
            isBold: (try? c.decode(Bool.self, forKey: .isBold)) ?? inferredTraits.contains(.traitBold),
            isItalic: (try? c.decode(Bool.self, forKey: .isItalic)) ?? inferredTraits.contains(.traitItalic),
            isUnderlined: (try? c.decode(Bool.self, forKey: .isUnderlined)) ?? defaults.isUnderlined,
            isStruckThrough: (try? c.decode(Bool.self, forKey: .isStruckThrough)) ?? defaults.isStruckThrough,
            isOverlined: (try? c.decode(Bool.self, forKey: .isOverlined)) ?? defaults.isOverlined,
            color: (try? c.decode(RGBA.self, forKey: .color)) ?? defaults.color,
            alignment: (try? c.decode(Alignment.self, forKey: .alignment)) ?? defaults.alignment,
            blur: (try? c.decode(Double.self, forKey: .blur)) ?? defaults.blur,
            shadow: (try? c.decode(Shadow.self, forKey: .shadow)) ?? defaults.shadow,
            background: (try? c.decode(Background.self, forKey: .background)) ?? defaults.background,
            border: (try? c.decode(Outline.self, forKey: .border)) ?? defaults.border
        )
    }
}

// MARK: - Rendering helpers

extension TextStyle.RGBA {
    mutating func setRGB(from color: Self) {
        r = color.r
        g = color.g
        b = color.b
    }

    var nsColor: NSColor {
        NSColor(
            srgbRed: CGFloat(r),
            green: CGFloat(g),
            blue: CGFloat(b),
            alpha: CGFloat(a)
        )
    }

    var swiftUIColor: Color {
        Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }

    var hexString: String {
        let bytes = [r, g, b, a].map { Int((min(max($0, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", bytes[0], bytes[1], bytes[2], bytes[3])
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(
            r: Double(ns.redComponent),
            g: Double(ns.greenComponent),
            b: Double(ns.blueComponent),
            a: Double(ns.alphaComponent)
        )
    }

    /// Accepts `#RGB`, `#RRGGBB`, or `#RRGGBBAA`. Leading `#` optional.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let chars = Array(s)
        func component(_ start: Int, _ len: Int) -> Double? {
            let slice = String(chars[start..<start + len])
            let byteStr = len == 1 ? slice + slice : slice
            guard let n = UInt8(byteStr, radix: 16) else { return nil }
            return Double(n) / 255.0
        }
        switch chars.count {
        case 3:
            guard let r = component(0, 1), let g = component(1, 1), let b = component(2, 1) else { return nil }
            self.init(r: r, g: g, b: b, a: 1)
        case 6:
            guard let r = component(0, 2), let g = component(2, 2), let b = component(4, 2) else { return nil }
            self.init(r: r, g: g, b: b, a: 1)
        case 8:
            guard let r = component(0, 2), let g = component(2, 2),
                  let b = component(4, 2), let a = component(6, 2) else { return nil }
            self.init(r: r, g: g, b: b, a: a)
        default:
            return nil
        }
    }
}

extension TextStyle {
    nonisolated(unsafe) private static let resolvedFontCache: NSCache<NSString, NSFont> = {
        let cache = NSCache<NSString, NSFont>()
        cache.countLimit = 512
        return cache
    }()

    var scaledVisualStyle: TextStyle {
        guard fontScale != 1 else { return self }
        var style = self
        style.fontSize *= fontScale
        style.tracking *= fontScale
        style.lineSpacing *= fontScale
        style.shadow.offsetX *= fontScale
        style.shadow.offsetY *= fontScale
        style.shadow.blur *= fontScale
        style.border.width *= fontScale
        style.background.paddingX *= fontScale
        style.background.paddingY *= fontScale
        style.background.cornerRadius *= fontScale
        style.background.offsetX *= fontScale
        style.background.offsetY *= fontScale
        style.background.outlineWidth *= fontScale
        style.fontScale = 1
        return style
    }

    func resolvedFont(size: CGFloat) -> NSFont {
        let key = "\(fontName.utf8.count):\(fontName)|\(Double(size).bitPattern)|\(isBold)|\(isItalic)|\(widthScale.bitPattern)|\(heightScale.bitPattern)" as NSString
        if let cached = Self.resolvedFontCache.object(forKey: key) { return cached }

        let namedBase = NSFont(name: fontName, size: size)
        let base = namedBase ?? NSFont.systemFont(ofSize: size)
        var resolved = Self.font(base, size: size, bold: isBold, italic: isItalic)
        if widthScale != 1 || heightScale != 1 {
            var transform = CGAffineTransform(scaleX: CGFloat(widthScale), y: CGFloat(heightScale))
            resolved = CTFontCreateCopyWithAttributes(resolved as CTFont, size, &transform, nil) as NSFont
        }
        // A bundled font may not be registered yet; do not cache its fallback.
        if namedBase != nil { Self.resolvedFontCache.setObject(resolved, forKey: key) }
        return resolved
    }

    var nsColor: NSColor { color.nsColor }

    func paragraphStyle(size: CGFloat, alignment override: NSTextAlignment? = nil) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        if let override {
            p.alignment = override
        } else {
            switch alignment {
            case .left: p.alignment = .left
            case .center: p.alignment = .center
            case .right: p.alignment = .right
            }
        }
        p.lineBreakMode = .byWordWrapping
        let scaledSpacing = lineSpacing * Double(size) / max(1, fontSize * fontScale)
        p.lineSpacing = CGFloat(scaledSpacing.isFinite ? scaledSpacing : 0)
        return p
    }

    func displayText(_ text: String) -> String {
        fontCase.apply(to: text)
    }

    /// Two-pass outlines need an opaque fill; translucent fills would show the undercoat through them.
    var drawsGlyphOutline: Bool {
        border.enabled && border.width > 0 && color.a >= 1
    }

    /// `includeColor: false` for bounding measurement (color doesn't affect size).
    func attributes(size: CGFloat, includeColor: Bool = true) -> [NSAttributedString.Key: Any] {
        var attrs = baseAttributes(size: size)
        if isUnderlined { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if isStruckThrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if includeColor { attrs[.foregroundColor] = nsColor }
        if border.enabled, border.width > 0, !drawsGlyphOutline {
            attrs[.strokeWidth] = NSNumber(value: -100 * max(0, border.width) / max(1, fontSize * fontScale))
            if includeColor { attrs[.strokeColor] = border.color.nsColor }
        }
        return attrs
    }

    /// Stroke-only undercoat at 2× width; the fill drawn on top covers the inner half, leaving `border.width` outward.
    func outlineUndercoatAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        var attrs = baseAttributes(size: size)
        attrs[.strokeWidth] = NSNumber(value: 200 * max(0, border.width) / max(1, fontSize * fontScale))
        attrs[.strokeColor] = border.color.nsColor
        return attrs
    }

    func glyphBorderPadding(fontSize: CGFloat) -> CGFloat {
        ceil(fontSize * CGFloat(max(0, border.width)) / CGFloat(max(1, self.fontSize * fontScale)))
    }

    private func baseAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: resolvedFont(size: size),
            .paragraphStyle: paragraphStyle(size: size),
            .kern: tracking * Double(size) / max(1, fontSize * fontScale),
        ]
    }

    private static func font(_ font: NSFont, size: CGFloat, bold: Bool, italic: Bool) -> NSFont {
        var traits = CTFontGetSymbolicTraits(font as CTFont)
        if bold { traits.insert(.traitBold) } else { traits.remove(.traitBold) }
        if italic { traits.insert(.traitItalic) } else { traits.remove(.traitItalic) }

        let mask: CTFontSymbolicTraits = [.traitBold, .traitItalic]
        let descriptor = CTFontCopyFontDescriptor(font as CTFont)
        guard let resolvedDescriptor = CTFontDescriptorCreateCopyWithSymbolicTraits(descriptor, traits, mask) else {
            return font
        }
        return CTFontCreateWithFontDescriptor(resolvedDescriptor, size, nil) as NSFont
    }

    private static func symbolicTraits(fontName: String, size: CGFloat) -> CTFontSymbolicTraits {
        guard let font = NSFont(name: fontName, size: size) else { return [] }
        return CTFontGetSymbolicTraits(font as CTFont)
    }
}
