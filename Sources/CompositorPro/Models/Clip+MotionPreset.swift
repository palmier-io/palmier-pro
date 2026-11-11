import Foundation

enum MotionPreset: String, CaseIterable, Codable, Sendable {
    case fadeIn
    case slideUp
    case punchIn
    case gentlePush

    var displayName: String {
        switch self {
        case .fadeIn: L10n.key("Fade In")
        case .slideUp: L10n.key("Slide Up")
        case .punchIn: L10n.key("Punch In")
        case .gentlePush: L10n.key("Gentle Push")
        }
    }
}

extension Clip {
    /// Applies motivated keyframe animation presets to a visual clip.
    mutating func applyMotionPreset(_ preset: MotionPreset, requestedDuration: Int? = nil) {
        let lastFrame = max(1, durationFrames - 1)
        let entrance = min(lastFrame, requestedDuration ?? min(15, lastFrame))
        let topLeft = transform.topLeft
        let basePosition = AnimPair(a: topLeft.x, b: topLeft.y)
        let baseScale = AnimPair(a: transform.width, b: transform.height)
        switch preset {
        case .fadeIn:
            opacityTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: 0, interpolationOut: .smooth),
                Keyframe(frame: entrance, value: opacity, interpolationOut: .smooth),
            ])
        case .slideUp:
            opacityTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: 0, interpolationOut: .smooth),
                Keyframe(frame: entrance, value: opacity, interpolationOut: .smooth),
            ])
            positionTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: AnimPair(a: topLeft.x, b: topLeft.y + 0.05), interpolationOut: .smooth),
                Keyframe(frame: entrance, value: basePosition, interpolationOut: .smooth),
            ])
        case .punchIn:
            opacityTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: 0, interpolationOut: .smooth),
                Keyframe(frame: entrance, value: opacity, interpolationOut: .smooth),
            ])
            scaleTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: AnimPair(a: baseScale.a * 0.9, b: baseScale.b * 0.9), interpolationOut: .smooth),
                Keyframe(frame: entrance, value: baseScale, interpolationOut: .smooth),
            ])
        case .gentlePush:
            scaleTrack = KeyframeTrack(keyframes: [
                Keyframe(frame: 0, value: baseScale, interpolationOut: .linear),
                Keyframe(frame: lastFrame, value: AnimPair(a: baseScale.a * 1.06, b: baseScale.b * 1.06), interpolationOut: .linear),
            ])
        }
    }
}
