import CoreGraphics
import Foundation

/// Where the edit is going, and therefore what the platform's own interface will cover.
///
/// This is the single owner of delivery-dependent layout. Caption placement, the preview guide
/// overlay and the agent tools all read these numbers, so a caption cannot land under TikTok's
/// buttons while the guide overlay draws a different box.
///
/// The non-`generic` figures are **conservative working areas, not published platform spec**. No
/// platform publishes exact overlay dimensions, and they change without notice. These are tuned so
/// text stays clear of the interface and legible, and they are deliberately larger than the
/// interface really needs. Treat them as a floor for safety, not as a specification.
enum DeliveryPlatform: String, CaseIterable, Sendable, Identifiable {
    /// No platform interface. This preserves the existing caption placement exactly.
    case generic
    case youtube
    case tiktokShorts
    case instagramReels

    var id: String { rawValue }

    /// Fractions of the picture the destination's own interface is expected to cover.
    var coveredArea: EdgeFractions {
        switch self {
        case .generic:
            // bottom is set so the derived caption centre is exactly the historical 0.90.
            EdgeFractions(top: 0.05, bottom: 0.08, left: 0.05, right: 0.05)
        case .youtube:
            EdgeFractions(top: 0.10, bottom: 0.10, left: 0.10, right: 0.10)
        case .tiktokShorts:
            // Right-hand action rail, and the caption plus button stack along the bottom.
            EdgeFractions(top: 0.08, bottom: 0.20, left: 0.04, right: 0.14)
        case .instagramReels:
            EdgeFractions(top: 0.07, bottom: 0.22, left: 0.04, right: 0.13)
        }
    }

    /// True when `coveredArea` is an estimate rather than a published figure.
    var coveredAreaIsEstimate: Bool { self != .generic }

    /// Where a caption goes when the caller has not asked for a specific position.
    ///
    /// Centred across the uncovered width and as low as the safe area allows, derived from
    /// `coveredArea` so there is only one set of numbers to reason about. It is exactly the
    /// clamp's upper bound, so the default is never itself "clamped".
    func defaultCaptionPlacement() -> CaptionPlacement {
        let area = coveredArea
        let rect = area.captionSafeRect
        return CaptionPlacement(
            centerX: 0.5,
            centerY: rect.maxY - Self.captionClearance,
            maxWidth: rect.width
        )
    }

    /// Breathing room between the bottom of a caption and the platform interface, as a fraction
    /// of canvas height.
    static let captionClearance: Double = 0.02

    struct EdgeFractions: Sendable, Equatable {
        var top: Double
        var bottom: Double
        var left: Double
        var right: Double

        init(top: Double, bottom: Double, left: Double, right: Double) {
            self.top = top.clampedToUnit()
            self.bottom = bottom.clampedToUnit()
            self.left = left.clampedToUnit()
            self.right = right.clampedToUnit()
        }

        /// The rectangle a caption must stay inside to clear the interface.
        var captionSafeRect: CGRect {
            CGRect(
                x: left, y: top,
                width: max(0.01, 1 - left - right),
                height: max(0.01, 1 - top - bottom)
            )
        }
    }

    /// Normalized placement for a caption block, as fractions of the canvas.
    struct CaptionPlacement: Sendable, Equatable {
        var centerX: Double
        var centerY: Double
        /// Widest the text may run, as a fraction of canvas width.
        var maxWidth: Double

        /// Pulls a placement inside the platform's covered area. A caller-supplied position is
        /// honoured unless it would land underneath the interface. The centre is bounded rather
        /// than the block, because the block's height is not known here.
        func clamped(into area: EdgeFractions) -> CaptionPlacement {
            let rect = area.captionSafeRect
            let lowerY = rect.minY + DeliveryPlatform.captionClearance
            let upperY = max(lowerY, rect.maxY - DeliveryPlatform.captionClearance)
            let width = maxWidth.isFinite ? maxWidth : rect.width
            return CaptionPlacement(
                centerX: centerX.clamped(to: rect.minX ... rect.maxX),
                centerY: centerY.clamped(to: lowerY ... upperY),
                maxWidth: width.clamped(to: 0.01 ... rect.width)
            )
        }
    }
}

private extension Double {
    func clampedToUnit() -> Double { clamped(to: 0 ... 1) }
    func clamped(to range: ClosedRange<Double>) -> Double {
        guard isFinite else { return range.lowerBound }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}