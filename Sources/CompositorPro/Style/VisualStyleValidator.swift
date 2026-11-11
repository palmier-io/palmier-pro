import Foundation
import SwiftUI

/// Validates a `VisualStyle` for contrast and color-blind safety.
///
/// Port of OpenMontage's `playbook_loader.py` validation (WCAG 2.1 contrast
/// + deuteranopia/protanopia/tritanopia confusion), reimplemented in pure
/// Swift with no external dependencies.
enum VisualStyleValidator {

    /// Minimum contrast ratio for normal text (WCAG AA).
    static let aaNormalContrast: Double = 4.5
    /// Minimum contrast ratio for large text (WCAG AA).
    static let aaLargeContrast: Double = 3.0

    /// Result of a single contrast check.
    struct ContrastIssue: Sendable, Equatable {
        var pair: String
        var ratio: Double
        var severity: Severity
        var message: String
    }

    enum Severity: String, Codable, Sendable, CaseIterable {
        case error, warning, info
    }

    /// Full validation result.
    struct Report: Sendable, Equatable {
        var pass: Bool
        var errorCount: Int
        var warningCount: Int
        var totalIssues: Int
        var issues: [ContrastIssue]
    }

    // MARK: - Entry point

    /// Validates a playbook: contrast on all text/bg pairs, overlay pairs,
    /// and color-blind safety on primary + accent + chart palette.
    static func validate(_ style: VisualStyle) -> Report {
        var issues: [ContrastIssue] = []

        guard let bg = style.backgroundRGBA, let text = style.textRGBA else {
            return Report(pass: false, errorCount: 1, warningCount: 0, totalIssues: 1,
                          issues: [ContrastIssue(pair: "missing background or text color",
                                                 ratio: 0, severity: .error,
                                                 message: "Style is missing background or text color.")])
        }

        // Main text on background.
        if let issue = contrastIssue(fg: text, bg: bg, pair: "text on background") {
            issues.append(issue)
        }

        // Muted text on background.
        if let muted = style.mutedRGBA {
            if let issue = contrastIssue(fg: muted, bg: bg, pair: "muted on background") {
                issues.append(issue)
            }
        }

        // Overlay text on overlay background.
        if let overlays = style.overlays {
            let mirror: [String: VisualStyle.OverlayStyle?] = [
                "stat_card": overlays.statCard,
                "key_term": overlays.keyTerm,
                "code_block": overlays.codeBlock,
                "section_title": overlays.sectionTitle,
                "stat_reveal": overlays.statReveal,
                "hero_title": overlays.heroTitle,
                "provider_chip": overlays.providerChip,
            ]
            for (name, overlay) in mirror {
                guard let o = overlay,
                      let oBgStr = o.bg, let oBg = TextStyle.RGBA(hex: oBgStr),
                      let oTextStr = o.text, let oText = TextStyle.RGBA(hex: oTextStr)
                else { continue }
                let compBg = compositeAlpha(fg: oBg, bg: bg)
                let compText = compositeAlpha(fg: oText, bg: bg)
                if let issue = contrastIssue(fg: compText, bg: compBg,
                                             pair: "overlay.\(name): text on bg") {
                    issues.append(issue)
                }
            }
        }

        // Color-blind safety on primary + accent + chart palette.
        var allColors: [TextStyle.RGBA] = []
        allColors.append(contentsOf: style.primaryRGBA)
        allColors.append(contentsOf: style.accentRGBA)
        allColors.append(contentsOf: style.chartPaletteRGBA)
        if allColors.count >= 2 {
            for issue in colorBlindIssues(colors: allColors) {
                issues.append(ContrastIssue(
                    pair: "\(issue.colorA.hexString) / \(issue.colorB.hexString)",
                    ratio: 0,
                    severity: .warning,
                    message: issue.message
                ))
            }
        }

        let errorCount = issues.filter { $0.severity == .error }.count
        let warningCount = issues.filter { $0.severity == .warning }.count
        return Report(
            pass: errorCount == 0,
            errorCount: errorCount,
            warningCount: warningCount,
            totalIssues: issues.count,
            issues: issues
        )
    }

    // MARK: - Contrast

    private static func contrastIssue(
        fg: TextStyle.RGBA, bg: TextStyle.RGBA, pair: String
    ) -> ContrastIssue? {
        let ratio = contrastRatio(fg: fg, bg: bg)
        let passesAA = ratio >= aaNormalContrast
        if passesAA { return nil }
        let severity: Severity = ratio >= aaLargeContrast ? .warning : .error
        return ContrastIssue(
            pair: pair,
            ratio: ratio,
            severity: severity,
            message: severity == .error
                ? "Fails WCAG AA for normal text (ratio \(String(format: "%.2f", ratio)):1, need 4.5:1)"
                : "Passes AA for large text but not normal text (ratio \(String(format: "%.2f", ratio)):1)"
        )
    }

    /// WCAG 2.1 contrast ratio between two RGBA colors composited over opaque white.
    private static func contrastRatio(fg: TextStyle.RGBA, bg: TextStyle.RGBA) -> Double {
        let compFg = compositeAlpha(fg: fg, bg: TextStyle.RGBA(r: 1, g: 1, b: 1, a: 1))
        let compBg = compositeAlpha(fg: bg, bg: TextStyle.RGBA(r: 1, g: 1, b: 1, a: 1))
        let l1 = relativeLuminance(compFg)
        let l2 = relativeLuminance(compBg)
        let lighter = max(l1, l2), darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Composite an RGBA foreground over an opaque background.
    private static func compositeAlpha(fg: TextStyle.RGBA, bg: TextStyle.RGBA) -> TextStyle.RGBA {
        let a = fg.a
        return TextStyle.RGBA(
            r: a * fg.r + (1 - a) * bg.r,
            g: a * fg.g + (1 - a) * bg.g,
            b: a * fg.b + (1 - a) * bg.b,
            a: 1
        )
    }

    /// sRGB relative luminance.
    private static func relativeLuminance(_ c: TextStyle.RGBA) -> Double {
        0.2126 * linearize(c.r) + 0.7152 * linearize(c.g) + 0.0722 * linearize(c.b)
    }

    private static func linearize(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    // MARK: - Color-blind safety

    private static func colorBlindIssues(colors: [TextStyle.RGBA]) -> [(colorA: TextStyle.RGBA, colorB: TextStyle.RGBA, message: String)] {
        var issues: [(TextStyle.RGBA, TextStyle.RGBA, String)] = []
        let hues = colors.map { rgbToHsl($0) }

        let confusionPairs: [[(ClosedRange<Double>, ClosedRange<Double>)]] = [
            [(0...30, 90...150), (30...60, 90...130), (330...360, 90...150)],     // deuteranopia
            [(0...40, 80...140), (340...360, 80...140), (0...20, 170...200)],     // protanopia
            [(200...270, 50...100), (220...260, 40...80), (170...210, 300...340)], // tritanopia
        ]

        for i in hues.indices {
            for j in (i + 1)..<hues.count {
                let c1 = hues[i], c2 = hues[j]
                // Skip very desaturated colors (distinguishable by lightness).
                if c1.s < 0.15 || c2.s < 0.15 { continue }
                // Lightness difference alone saves them.
                if abs(c1.l - c2.l) > 0.3 { continue }

                for ranges in confusionPairs {
                    for (rangeA, rangeB) in ranges {
                        let aInA = rangeA.contains(c1.h), bInB = rangeB.contains(c2.h)
                        let aInB = rangeB.contains(c1.h), bInA = rangeA.contains(c2.h)
                        if (aInA && bInB) || (aInB && bInA) {
                            issues.append((colors[i], colors[j],
                                "\(colors[i].hexString) and \(colors[j].hexString) may be indistinguishable for color-blind viewers"))
                        }
                    }
                }
            }
        }
        return issues
    }

    /// RGB (0–1) → HSL (h: 0–360, s: 0–1, l: 0–1).
    private static func rgbToHsl(_ c: TextStyle.RGBA) -> (h: Double, s: Double, l: Double) {
        let maxc = max(c.r, c.g, c.b), minc = min(c.r, c.g, c.b)
        let l = (maxc + minc) / 2
        if maxc == minc { return (0, 0, l) }
        let d = maxc - minc
        let s = l > 0.5 ? d / (2 - maxc - minc) : d / (maxc + minc)
        let h: Double
        switch maxc {
        case c.r: h = (c.g - c.b) / d + (c.g < c.b ? 6 : 0)
        case c.g: h = (c.b - c.r) / d + 2
        default: h = (c.r - c.g) / d + 4
        }
        return (h * 60, s, l)
    }
}
