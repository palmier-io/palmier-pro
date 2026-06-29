import CoreGraphics

/// Pure per-frame evaluator for text animation
enum TextAnimator {
    struct ClipState: Equatable {
        var opacity: Float = 1
        var scale: CGFloat = 1
        /// Vertical offset as a fraction of render height (positive = down).
        var dy: CGFloat = 0
        static let identity = ClipState()
    }

    struct WordState: Equatable {
        var opacity: Float = 1
        var scale: CGFloat = 1
        var color: TextStyle.RGBA
    }

    /// Whole-clip entrance. Non-entrance presets return identity.
    static func clipEntry(_ anim: TextAnimation, rel: Int) -> ClipState {
        let dur = max(1, anim.perWordFrames)
        let t = progress(rel, start: 0, dur: dur)
        switch anim.preset {
        case .fadeIn:
            return ClipState(opacity: Float(t))
        case .popIn:
            return ClipState(opacity: Float(t), scale: 0.6 + 0.4 * CGFloat(t))
        case .slideUp:
            return ClipState(opacity: Float(t), dy: 0.05 * (1 - CGFloat(t)))
        default:
            return .identity
        }
    }

    /// Per-word karaoke state. `base` is the clip's static text color.
    static func wordState(_ anim: TextAnimation, word: WordTiming, rel: Int, base: TextStyle.RGBA) -> WordState {
        let highlight = anim.highlight ?? TextAnimation.defaultHighlight
        let hand = max(1, anim.perWordFrames)
        switch anim.preset {
        case .wordPop:
            let t = progress(rel, start: word.startFrame, dur: hand)
            return WordState(opacity: Float(t), scale: 0.6 + 0.4 * CGFloat(t), color: base)
        case .wordReveal:
            return WordState(opacity: rel >= word.startFrame ? 1 : 0, color: base)
        case .highlightPop:
            let on = activeRamp(rel, word: word, ramp: min(hand, 4))
            return WordState(scale: 1 + 0.15 * CGFloat(on), color: lerp(base, highlight, CGFloat(on)))
        case .karaokeFill:
            let on = activeRamp(rel, word: word, ramp: min(hand, 3))
            return WordState(color: lerp(base, highlight, CGFloat(on)))
        default:
            return WordState(color: base)
        }
    }

    // MARK: - Helpers

    /// Eased 0→1 ramp across `dur` frames starting at `start`.
    private static func progress(_ rel: Int, start: Int, dur: Int) -> Double {
        guard rel > start else { return 0 }
        guard rel < start + dur else { return 1 }
        return smoothstep(Double(rel - start) / Double(dur))
    }

    /// 0 outside the word's active span, ramping to 1 inside (eased at both edges).
    private static func activeRamp(_ rel: Int, word: WordTiming, ramp: Int) -> Double {
        guard rel >= word.startFrame, rel < word.endFrame else { return 0 }
        let r = max(1, ramp)
        let rampIn = smoothstep(min(1, Double(rel - word.startFrame) / Double(r)))
        let rampOut = smoothstep(min(1, Double(word.endFrame - rel) / Double(r)))
        return min(rampIn, rampOut)
    }

    private static func lerp(_ a: TextStyle.RGBA, _ b: TextStyle.RGBA, _ t: CGFloat) -> TextStyle.RGBA {
        let t = Double(min(1, max(0, t)))
        return TextStyle.RGBA(
            r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t,
            a: a.a + (b.a - a.a) * t
        )
    }
}
