import Foundation

/// Named preset animations the agent (and later UI) can apply to any clip.
/// Each preset compiles to a set of keyframe rows that drop into the clip's
/// existing tracks — so undo, export, and the inspector all just work.
enum AnimationPreset: String, CaseIterable, Sendable {
    case fadeIn       = "fade-in"
    case fadeOut      = "fade-out"
    case popIn        = "pop-in"
    case popOut       = "pop-out"
    case drawOn       = "draw-on"
    case unDraw       = "un-draw"
    case shakeSubtle  = "shake-subtle"
    case shakeStrong  = "shake-strong"
    case spin         = "spin"
    case slideInUp    = "slide-in-up"
    case slideInDown  = "slide-in-down"
    case slideInLeft  = "slide-in-left"
    case slideInRight = "slide-in-right"
    case slideOutUp    = "slide-out-up"
    case slideOutDown  = "slide-out-down"
    case slideOutLeft  = "slide-out-left"
    case slideOutRight = "slide-out-right"

    enum Kind: Sendable { case enter, exit, loop }

    var kind: Kind {
        switch self {
        case .fadeIn, .popIn, .drawOn, .slideInUp, .slideInDown, .slideInLeft, .slideInRight:
            return .enter
        case .fadeOut, .popOut, .unDraw, .slideOutUp, .slideOutDown, .slideOutLeft, .slideOutRight:
            return .exit
        case .shakeSubtle, .shakeStrong, .spin:
            return .loop
        }
    }
}

enum AnimationIntensity: String, Sendable {
    case subtle, medium, strong
}

/// The keyframes a preset produces, ready to merge into a Clip's tracks.
/// All frames are CLIP-RELATIVE (offset from clip's startFrame).
struct AnimationApplication: Sendable {
    var opacityKeyframes: [Keyframe<Double>]?
    var positionKeyframes: [Keyframe<AnimPair>]?
    var scaleKeyframes: [Keyframe<AnimPair>]?
    var rotationKeyframes: [Keyframe<Double>]?
    var strokeProgressKeyframes: [Keyframe<Double>]?
}

enum AnimationPresetEngine {
    static let defaultWindowFrames: Int = 15

    /// Compile a preset into a concrete keyframe application.
    /// - Parameters:
    ///   - preset: the named preset.
    ///   - windowFrames: enter / exit window length. Ignored for loop presets.
    ///   - clipDurationFrames: full clip length on the timeline.
    ///   - restingTransform: the clip's static transform (used as the slide-in target / shake origin).
    ///   - intensity: subtle / medium / strong.
    static func apply(
        preset: AnimationPreset,
        windowFrames: Int? = nil,
        clipDurationFrames: Int,
        restingTransform: Transform,
        intensity: AnimationIntensity = .medium
    ) -> AnimationApplication {
        let window = max(1, min(windowFrames ?? defaultWindowFrames, clipDurationFrames))
        switch preset {
        case .fadeIn:       return fadeIn(window: window)
        case .fadeOut:      return fadeOut(window: window, clipDuration: clipDurationFrames)
        case .popIn:        return popIn(window: window, target: restingTransform)
        case .popOut:       return popOut(window: window, clipDuration: clipDurationFrames, target: restingTransform)
        case .drawOn:       return drawOn(window: window)
        case .unDraw:       return unDraw(window: window, clipDuration: clipDurationFrames)
        case .shakeSubtle:  return shake(clipDuration: clipDurationFrames, target: restingTransform, intensity: .subtle)
        case .shakeStrong:  return shake(clipDuration: clipDurationFrames, target: restingTransform, intensity: .strong)
        case .spin:         return spin(clipDuration: clipDurationFrames, intensity: intensity)
        case .slideInUp:    return slideIn(window: window, target: restingTransform, dx: 0, dy: -1.5)
        case .slideInDown:  return slideIn(window: window, target: restingTransform, dx: 0, dy: 1.5)
        case .slideInLeft:  return slideIn(window: window, target: restingTransform, dx: -1.5, dy: 0)
        case .slideInRight: return slideIn(window: window, target: restingTransform, dx: 1.5, dy: 0)
        case .slideOutUp:    return slideOut(window: window, clipDuration: clipDurationFrames, target: restingTransform, dx: 0, dy: -1.5)
        case .slideOutDown:  return slideOut(window: window, clipDuration: clipDurationFrames, target: restingTransform, dx: 0, dy: 1.5)
        case .slideOutLeft:  return slideOut(window: window, clipDuration: clipDurationFrames, target: restingTransform, dx: -1.5, dy: 0)
        case .slideOutRight: return slideOut(window: window, clipDuration: clipDurationFrames, target: restingTransform, dx: 1.5, dy: 0)
        }
    }

    /// Merge a new application's keyframes into a clip. Preserves keyframes
    /// on properties this preset doesn't touch. Replaces (not appends) the
    /// rows on properties the preset DOES touch — overlapping a fade-in onto
    /// an existing fade-in is destructive on purpose.
    static func merge(_ application: AnimationApplication, into clip: inout Clip) {
        if let kfs = application.opacityKeyframes {
            clip.opacityTrack = kfs.isEmpty ? nil : KeyframeTrack(keyframes: dedupedSorted(kfs))
        }
        if let kfs = application.positionKeyframes {
            clip.positionTrack = kfs.isEmpty ? nil : KeyframeTrack(keyframes: dedupedSorted(kfs))
        }
        if let kfs = application.scaleKeyframes {
            clip.scaleTrack = kfs.isEmpty ? nil : KeyframeTrack(keyframes: dedupedSorted(kfs))
        }
        if let kfs = application.rotationKeyframes {
            clip.rotationTrack = kfs.isEmpty ? nil : KeyframeTrack(keyframes: dedupedSorted(kfs))
        }
        if let kfs = application.strokeProgressKeyframes {
            clip.strokeProgressTrack = kfs.isEmpty ? nil : KeyframeTrack(keyframes: dedupedSorted(kfs))
        }
    }

    // MARK: - Presets

    private static func fadeIn(window: Int) -> AnimationApplication {
        AnimationApplication(opacityKeyframes: [
            Keyframe(frame: 0, value: 0.0, interpolationOut: .smooth),
            Keyframe(frame: window, value: 1.0, interpolationOut: .smooth),
        ])
    }

    private static func fadeOut(window: Int, clipDuration: Int) -> AnimationApplication {
        let start = max(0, clipDuration - window)
        return AnimationApplication(opacityKeyframes: [
            Keyframe(frame: start, value: 1.0, interpolationOut: .smooth),
            Keyframe(frame: clipDuration, value: 0.0, interpolationOut: .smooth),
        ])
    }

    private static func popIn(window: Int, target: Transform) -> AnimationApplication {
        let tw = target.width, th = target.height
        let peakW = tw * 1.12
        let peakH = th * 1.12
        let peakFrame = max(1, Int(Double(window) * 0.7))
        let topLeft = target.topLeft
        let peakTL_x = topLeft.x - (peakW - tw) / 2
        let peakTL_y = topLeft.y - (peakH - th) / 2
        return AnimationApplication(
            positionKeyframes: [
                Keyframe(frame: 0,         value: AnimPair(a: topLeft.x + tw / 2, b: topLeft.y + th / 2), interpolationOut: .smooth),
                Keyframe(frame: peakFrame, value: AnimPair(a: peakTL_x,           b: peakTL_y),           interpolationOut: .smooth),
                Keyframe(frame: window,    value: AnimPair(a: topLeft.x,          b: topLeft.y),          interpolationOut: .smooth),
            ],
            scaleKeyframes: [
                Keyframe(frame: 0,         value: AnimPair(a: 0,     b: 0),     interpolationOut: .smooth),
                Keyframe(frame: peakFrame, value: AnimPair(a: peakW, b: peakH), interpolationOut: .smooth),
                Keyframe(frame: window,    value: AnimPair(a: tw,    b: th),    interpolationOut: .smooth),
            ]
        )
    }

    private static func popOut(window: Int, clipDuration: Int, target: Transform) -> AnimationApplication {
        let start = max(0, clipDuration - window)
        let tw = target.width, th = target.height
        let peakW = tw * 1.15
        let peakH = th * 1.15
        let peakFrame = start + max(1, Int(Double(window) * 0.3))
        let topLeft = target.topLeft
        let peakTL_x = topLeft.x - (peakW - tw) / 2
        let peakTL_y = topLeft.y - (peakH - th) / 2
        return AnimationApplication(
            positionKeyframes: [
                Keyframe(frame: start,        value: AnimPair(a: topLeft.x,           b: topLeft.y),          interpolationOut: .smooth),
                Keyframe(frame: peakFrame,    value: AnimPair(a: peakTL_x,            b: peakTL_y),           interpolationOut: .smooth),
                Keyframe(frame: clipDuration, value: AnimPair(a: topLeft.x + tw / 2,  b: topLeft.y + th / 2), interpolationOut: .smooth),
            ],
            scaleKeyframes: [
                Keyframe(frame: start,        value: AnimPair(a: tw,    b: th),    interpolationOut: .smooth),
                Keyframe(frame: peakFrame,    value: AnimPair(a: peakW, b: peakH), interpolationOut: .smooth),
                Keyframe(frame: clipDuration, value: AnimPair(a: 0,     b: 0),     interpolationOut: .smooth),
            ]
        )
    }

    private static func drawOn(window: Int) -> AnimationApplication {
        AnimationApplication(strokeProgressKeyframes: [
            Keyframe(frame: 0, value: 0.0, interpolationOut: .smooth),
            Keyframe(frame: window, value: 1.0, interpolationOut: .smooth),
        ])
    }

    private static func unDraw(window: Int, clipDuration: Int) -> AnimationApplication {
        let start = max(0, clipDuration - window)
        return AnimationApplication(strokeProgressKeyframes: [
            Keyframe(frame: start, value: 1.0, interpolationOut: .smooth),
            Keyframe(frame: clipDuration, value: 0.0, interpolationOut: .smooth),
        ])
    }

    private static func shake(clipDuration: Int, target: Transform, intensity: AnimationIntensity) -> AnimationApplication {
        let amplitude: Double = {
            switch intensity {
            case .subtle: return 0.005
            case .medium: return 0.012
            case .strong: return 0.025
            }
        }()
        let stepFrames = 2
        let count = max(2, clipDuration / stepFrames)
        let baseTopLeft = target.topLeft
        var kfs: [Keyframe<AnimPair>] = []
        kfs.reserveCapacity(count + 1)
        // Deterministic pseudo-random walk so playback is stable across redraws.
        for i in 0...count {
            let f = min(clipDuration, i * stepFrames)
            let phase = Double(i) * 1.7
            let dx = amplitude * sin(phase * 2.1)
            let dy = amplitude * cos(phase * 2.9)
            kfs.append(Keyframe(
                frame: f,
                value: AnimPair(a: baseTopLeft.x + dx, b: baseTopLeft.y + dy),
                interpolationOut: .linear
            ))
        }
        return AnimationApplication(positionKeyframes: kfs)
    }

    private static func spin(clipDuration: Int, intensity: AnimationIntensity) -> AnimationApplication {
        let rotations: Double = {
            switch intensity {
            case .subtle: return 0.5
            case .medium: return 1.0
            case .strong: return 2.0
            }
        }()
        return AnimationApplication(rotationKeyframes: [
            Keyframe(frame: 0, value: 0, interpolationOut: .linear),
            Keyframe(frame: clipDuration, value: 360.0 * rotations, interpolationOut: .linear),
        ])
    }

    private static func slideIn(window: Int, target: Transform, dx: Double, dy: Double) -> AnimationApplication {
        let topLeft = target.topLeft
        let startTL_x = topLeft.x + dx
        let startTL_y = topLeft.y + dy
        return AnimationApplication(positionKeyframes: [
            Keyframe(frame: 0,      value: AnimPair(a: startTL_x, b: startTL_y), interpolationOut: .smooth),
            Keyframe(frame: window, value: AnimPair(a: topLeft.x, b: topLeft.y), interpolationOut: .smooth),
        ])
    }

    private static func slideOut(window: Int, clipDuration: Int, target: Transform, dx: Double, dy: Double) -> AnimationApplication {
        let start = max(0, clipDuration - window)
        let topLeft = target.topLeft
        let endTL_x = topLeft.x + dx
        let endTL_y = topLeft.y + dy
        return AnimationApplication(positionKeyframes: [
            Keyframe(frame: start,        value: AnimPair(a: topLeft.x, b: topLeft.y), interpolationOut: .smooth),
            Keyframe(frame: clipDuration, value: AnimPair(a: endTL_x,   b: endTL_y),   interpolationOut: .smooth),
        ])
    }

    private static func dedupedSorted<V: Codable & Sendable & Equatable>(_ kfs: [Keyframe<V>]) -> [Keyframe<V>] {
        let sorted = kfs.sorted { $0.frame < $1.frame }
        var out: [Keyframe<V>] = []
        out.reserveCapacity(sorted.count)
        for kf in sorted {
            if out.last?.frame == kf.frame { out[out.count - 1] = kf } else { out.append(kf) }
        }
        return out
    }
}
