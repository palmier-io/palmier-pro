import CoreGraphics
import Foundation

enum CaptionWordAnimation: String, Codable, Sendable, CaseIterable {
    case none
    case pop
    case bounce
    case fadeUp

    var label: String {
        switch self {
        case .none: "Static"
        case .pop: "Pop"
        case .bounce: "Bounce"
        case .fadeUp: "Fade Up"
        }
    }

    var isAnimated: Bool { self != .none }

    func appearance(at frame: Int, wordStartFrame: Int) -> (scale: CGFloat, opacity: Float) {
        guard isAnimated else {
            return frame >= wordStartFrame ? (1, 1) : (1, 0)
        }
        let elapsed = frame - wordStartFrame
        guard elapsed >= 0 else { return startAppearance(for: self) }

        let duration = AppTheme.Caption.wordAnimationDurationFrames
        if elapsed >= duration { return (1, 1) }

        let t = Double(elapsed) / Double(max(1, duration))
        switch self {
        case .none:
            return (1, 1)
        case .pop:
            let eased = 1 - pow(1 - t, 3)
            return (
                CGFloat(AppTheme.Caption.wordPopStartScale + (1 - AppTheme.Caption.wordPopStartScale) * eased),
                Float(eased)
            )
        case .bounce:
            let overshoot = 1 + 0.18 * sin(t * .pi)
            let scale = AppTheme.Caption.wordPopStartScale + (overshoot - AppTheme.Caption.wordPopStartScale) * t
            return (CGFloat(min(scale, 1.12)), Float(min(t * 1.4, 1)))
        case .fadeUp:
            let eased = 1 - pow(1 - t, 2)
            return (1, Float(eased))
        }
    }

    func verticalOffset(at frame: Int, wordStartFrame: Int) -> CGFloat {
        guard self == .fadeUp else { return 0 }
        let elapsed = frame - wordStartFrame
        guard elapsed >= 0 else { return AppTheme.Caption.wordFadeUpOffset }
        let duration = AppTheme.Caption.wordAnimationDurationFrames
        if elapsed >= duration { return 0 }
        let t = Double(elapsed) / Double(max(1, duration))
        let eased = 1 - pow(1 - t, 2)
        return CGFloat((1 - eased) * AppTheme.Caption.wordFadeUpOffset)
    }

    private func startAppearance(for kind: CaptionWordAnimation) -> (scale: CGFloat, opacity: Float) {
        switch kind {
        case .fadeUp: (1, 0)
        default: (CGFloat(AppTheme.Caption.wordPopStartScale), 0)
        }
    }
}

struct CaptionWordTiming: Codable, Sendable, Equatable {
    var text: String
    var startFrame: Int
    var endFrame: Int
}
