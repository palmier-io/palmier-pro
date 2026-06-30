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
        var dy: CGFloat = 0
        var color: TextStyle.RGBA
        var bgColor: TextStyle.RGBA?
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

    /// Per-word state. `base` is the clip's static text color.
    static func wordState(_ anim: TextAnimation, word: WordTiming, rel: Int, base: TextStyle.RGBA) -> WordState {
        let highlight = anim.highlight ?? TextAnimation.defaultHighlight
        let hand = max(1, anim.perWordFrames)
        switch anim.preset {
        case .wordReveal:
            let t = progress(rel, start: word.startFrame, dur: hand)
            return WordState(opacity: Float(t), color: activeTint(anim, word, rel, base))
        case .wordSlide:
            let t = progress(rel, start: word.startFrame, dur: hand)
            return WordState(opacity: Float(t), dy: 0.5 * (1 - CGFloat(t)), color: activeTint(anim, word, rel, base))
        case .wordPop:
            let u = linear(rel, start: word.startFrame, dur: hand)
            return WordState(opacity: Float(smoothstep(u)), scale: 0.6 + 0.4 * overshoot(u),
                             color: activeTint(anim, word, rel, base))
        case .wordCycle:
            let on = activeRamp(rel, word: word, ramp: hand)
            return WordState(opacity: Float(on), color: activeTint(anim, word, rel, base))
        case .highlightPop:
            let on = activeRamp(rel, word: word, ramp: min(hand, 4))
            return WordState(scale: 1 + 0.15 * CGFloat(on), color: lerp(base, highlight, CGFloat(on)))
        case .highlightBlock:
            let on = activeRamp(rel, word: word, ramp: min(hand, 4))
            var bg = highlight; bg.a *= Double(on)
            return WordState(color: base, bgColor: bg)
        default:
            return WordState(color: base)
        }
    }

    /// Tints the active word if a highlight is set.
    private static func activeTint(_ anim: TextAnimation, _ word: WordTiming, _ rel: Int, _ base: TextStyle.RGBA) -> TextStyle.RGBA {
        guard let hl = anim.highlight else { return base }
        let on = activeRamp(rel, word: word, ramp: max(1, anim.perWordFrames))
        return lerp(base, hl, CGFloat(on))
    }

    // MARK: - Helpers

    /// Eased 0→1 ramp across `dur` frames starting at `start`.
    private static func progress(_ rel: Int, start: Int, dur: Int) -> Double {
        smoothstep(linear(rel, start: start, dur: dur))
    }

    /// Raw (un-eased) 0→1 ramp across `dur` frames starting at `start`.
    private static func linear(_ rel: Int, start: Int, dur: Int) -> Double {
        guard rel > start else { return 0 }
        guard rel < start + dur else { return 1 }
        return Double(rel - start) / Double(dur)
    }

    /// Back-ease that overshoots past 1 before settling — a spring/bounce on the way in.
    private static func overshoot(_ t: Double) -> CGFloat {
        let s = 1.70158, p = t - 1
        return CGFloat(1 + (s + 1) * p * p * p + s * p * p)
    }

    /// 0 outside the active span, with the ramp shortened so fast words reach 1.
    private static func activeRamp(_ rel: Int, word: WordTiming, ramp: Int) -> Double {
        guard rel >= word.startFrame, rel < word.endFrame else { return 0 }
        let span = max(1, word.endFrame - word.startFrame)
        guard span > 1 else { return 1 }
        let r = min(max(1, ramp), max(1, span / 2))
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
