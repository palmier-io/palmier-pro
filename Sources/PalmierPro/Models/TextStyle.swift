import AppKit
import CoreText
import SwiftUI

struct TextStyle: Codable, Sendable, Equatable, Hashable {
    var fontName: String = "Helvetica-Bold"
    var fontSize: Double = 96
    var fontScale: Double = 1.0
    var tracking: Double = 0
    var lineSpacing: Double = 0
    var fontCase: FontCase = .mixed
    var isBold: Bool = true
    var isItalic: Bool = false
    var isUnderlined: Bool = false
    var isStruckThrough: Bool = false
    var isOverlined: Bool = false
    var color: RGBA = RGBA()
    var alignment: Alignment = .center
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
            case .mixed: "Mixed"
            case .uppercase: "UPPERCASE"
            case .lowercase: "lowercase"
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
        var enabled: Bool = true
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
        case fontName, fontSize, fontScale, tracking, lineSpacing, fontCase
        case isBold, isItalic, isUnderlined, isStruckThrough, isOverlined
        case color, alignment, shadow, background, border
    }
}

extension TextStyle {
    /// Missing-key-tolerant decode — older files pick up defaults for fields added later.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fontName = (try? c.decode(String.self, forKey: .fontName)) ?? "Helvetica-Bold"
        let fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? 96
        let inferredTraits = Self.symbolicTraits(fontName: fontName, size: CGFloat(fontSize))
        self.init(
            fontName: fontName,
            fontSize: fontSize,
            fontScale: (try? c.decode(Double.self, forKey: .fontScale)) ?? 1.0,
            tracking: (try? c.decode(Double.self, forKey: .tracking)) ?? 0,
            lineSpacing: (try? c.decode(Double.self, forKey: .lineSpacing)) ?? 0,
            fontCase: (try? c.decode(FontCase.self, forKey: .fontCase)) ?? .mixed,
            isBold: (try? c.decode(Bool.self, forKey: .isBold)) ?? inferredTraits.contains(.traitBold),
            isItalic: (try? c.decode(Bool.self, forKey: .isItalic)) ?? inferredTraits.contains(.traitItalic),
            isUnderlined: (try? c.decode(Bool.self, forKey: .isUnderlined)) ?? false,
            isStruckThrough: (try? c.decode(Bool.self, forKey: .isStruckThrough)) ?? false,
            isOverlined: (try? c.decode(Bool.self, forKey: .isOverlined)) ?? false,
            color: (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA(),
            alignment: (try? c.decode(Alignment.self, forKey: .alignment)) ?? .center,
            shadow: (try? c.decode(Shadow.self, forKey: .shadow)) ?? Shadow(),
            background: (try? c.decode(Background.self, forKey: .background)) ?? Background(),
            border: (try? c.decode(Outline.self, forKey: .border)) ?? Outline()
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
    func resolvedFont(size: CGFloat) -> NSFont {
        let base = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        return Self.font(base, size: size, bold: isBold, italic: isItalic)
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

    /// `includeColor: false` for bounding measurement (color doesn't affect size).
    func attributes(size: CGFloat, includeColor: Bool = true) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: resolvedFont(size: size),
            .paragraphStyle: paragraphStyle(size: size),
            .kern: tracking * Double(size) / max(1, fontSize * fontScale),
        ]
        if isUnderlined { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if isStruckThrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if includeColor { attrs[.foregroundColor] = nsColor }
        if border.enabled {
            attrs[.strokeWidth] = NSNumber(value: glyphBorderStrokePercentage)
            if includeColor { attrs[.strokeColor] = border.color.nsColor }
        }
        return attrs
    }

    func glyphBorderPadding(fontSize: CGFloat) -> CGFloat {
        ceil(fontSize * CGFloat(abs(glyphBorderStrokePercentage)) / 100)
    }

    private var glyphBorderStrokePercentage: Double {
        let unscaledFontSize = max(1, fontSize * fontScale)
        return -100 * max(0, border.width) / unscaledFontSize
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
