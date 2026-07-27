import AppKit
import CoreText
import SwiftUI

// TextStyle data model + Codable + scaledVisualStyle + displayText + RGBA hex live
// in PalmierCore and are re-exported. This file holds only the AppKit/CoreText/
// SwiftUI rendering surface and the platform font-trait inference hook that
// requires NSFont/CTFont.

// MARK: - Platform font-trait inference registration

private enum TextStyleInferenceRegistration {
    static let registered: Bool = {
        TextStyle.usePlatformFontTraitInference { fontName, size in
            guard let font = NSFont(name: fontName, size: CGFloat(size)) else { return (false, false) }
            let traits = CTFontGetSymbolicTraits(font as CTFont)
            return (traits.contains(.traitBold), traits.contains(.traitItalic))
        }
        return true
    }()
}

@inline(__always)
private func ensureTextStyleInferenceRegistered() { _ = TextStyleInferenceRegistration.registered }

// MARK: - Color conversions

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
}

// MARK: - Font + paragraph rendering

extension TextStyle {
    var nsColor: NSColor { color.nsColor }

    func resolvedFont(size: CGFloat) -> NSFont {
        ensureTextStyleInferenceRegistered()
        let base = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
        let resolved = Self.font(base, size: size, bold: isBold, italic: isItalic)
        guard widthScale != 1 || heightScale != 1 else { return resolved }
        var transform = CGAffineTransform(
            scaleX: CGFloat(widthScale),
            y: CGFloat(heightScale)
        )
        return CTFontCreateCopyWithAttributes(resolved as CTFont, size, &transform, nil) as NSFont
    }

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
}
