import AppKit
import CoreText
import SwiftUI

struct TextStyle: Codable, Sendable, Equatable, Hashable {
    static let glyphBorderStrokeWidth: Double = -4

    var fontName: String = "Helvetica-Bold"
    var fontSize: Double = 96
    var fontScale: Double = 1.0
    var isBold: Bool = true
    var isItalic: Bool = false
    var color: RGBA = RGBA()
    var alignment: Alignment = .center
    var shadow: Shadow = Shadow()
    var background: Fill = Fill(enabled: false, color: RGBA(r: 0, g: 0, b: 0, a: 0.6))
    var border: Fill = Fill(enabled: false, color: RGBA(r: 0, g: 0, b: 0, a: 1))

    enum Alignment: String, Codable, Sendable, CaseIterable, Hashable {
        case left
        case center
        case right
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

    /// Toggleable solid color for text box fill and glyph outline.
    struct Fill: Codable, Sendable, Equatable, Hashable {
        var enabled: Bool = false
        var color: RGBA = RGBA()
    }

    private enum CodingKeys: String, CodingKey {
        case fontName, fontSize, fontScale, isBold, isItalic, color, alignment, shadow, background, border
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
            isBold: (try? c.decode(Bool.self, forKey: .isBold)) ?? inferredTraits.contains(.traitBold),
            isItalic: (try? c.decode(Bool.self, forKey: .isItalic)) ?? inferredTraits.contains(.traitItalic),
            color: (try? c.decode(RGBA.self, forKey: .color)) ?? RGBA(),
            alignment: (try? c.decode(Alignment.self, forKey: .alignment)) ?? .center,
            shadow: (try? c.decode(Shadow.self, forKey: .shadow)) ?? Shadow(),
            background: (try? c.decode(Fill.self, forKey: .background)) ?? Fill(enabled: false, color: RGBA(r: 0, g: 0, b: 0, a: 0.6)),
            border: (try? c.decode(Fill.self, forKey: .border)) ?? Fill(enabled: false, color: RGBA(r: 0, g: 0, b: 0, a: 1))
        )
    }
}

// MARK: - Rendering helpers

extension TextStyle.RGBA {
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

    var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        switch alignment {
        case .left: p.alignment = .left
        case .center: p.alignment = .center
        case .right: p.alignment = .right
        }
        p.lineBreakMode = .byWordWrapping
        return p
    }

    /// `includeColor: false` for bounding measurement (color doesn't affect size).
    func attributes(size: CGFloat, includeColor: Bool = true) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: resolvedFont(size: size),
            .paragraphStyle: paragraphStyle,
        ]
        if includeColor { attrs[.foregroundColor] = nsColor }
        if border.enabled {
            attrs[.strokeWidth] = NSNumber(value: Self.glyphBorderStrokeWidth)
            if includeColor { attrs[.strokeColor] = border.color.nsColor }
        }
        return attrs
    }

    static func glyphBorderPadding(fontSize: CGFloat) -> CGFloat {
        ceil(fontSize * CGFloat(abs(glyphBorderStrokeWidth)) / 100)
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

extension TextStyle.Alignment {
    var caTextAlignmentMode: CATextLayerAlignmentMode {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }
}
