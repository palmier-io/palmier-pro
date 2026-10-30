import Foundation

extension Effect {
    static let gaussianBlurType = "blur.gaussian"
    static let gaussianBlurRadiusKey = "radius"
}

extension Clip {
    var blurKeyframeTrack: KeyframeTrack<Double>? {
        gaussianBlurEffect?.params[Effect.gaussianBlurRadiusKey]?.track
    }

    var staticBlurRadius: Double {
        if mediaType == .text {
            return textStyle?.blur ?? 0
        }
        return gaussianBlurEffect?.params[Effect.gaussianBlurRadiusKey]?.value ?? 0
    }

    func blurRadius(at frame: Int) -> Double {
        blurKeyframeTrack?.sample(
            at: frame - startFrame,
            fallback: staticBlurRadius
        ) ?? staticBlurRadius
    }

    mutating func setStaticBlurRadius(_ radius: Double) {
        guard radius.isFinite else { return }
        let radius = min(100, max(0, radius))
        if mediaType == .text {
            var style = textStyle ?? TextStyle()
            style.blur = radius
            textStyle = style
            return
        }

        var stack = effects ?? []
        let enabled = stack.first { $0.type == Effect.gaussianBlurType }?.enabled ?? true
        stack.removeAll { $0.type == Effect.gaussianBlurType }
        if radius > 0 {
            var effect = Effect.make(Effect.gaussianBlurType, [Effect.gaussianBlurRadiusKey: radius])
            effect.enabled = enabled
            stack.insert(
                effect,
                at: EffectRegistry.insertIndex(stack, for: Effect.gaussianBlurType)
            )
        }
        effects = stack.isEmpty ? nil : stack
    }

    mutating func setBlurKeyframeTrack(_ track: KeyframeTrack<Double>?) {
        let track = track?.isActive == true ? track : nil
        var stack = effects ?? []
        if let track {
            let index: Int
            if let existing = stack.firstIndex(where: { $0.type == Effect.gaussianBlurType }) {
                index = existing
            } else {
                index = EffectRegistry.insertIndex(stack, for: Effect.gaussianBlurType)
                stack.insert(
                    Effect.make(Effect.gaussianBlurType, [Effect.gaussianBlurRadiusKey: staticBlurRadius]),
                    at: index
                )
            }
            var param = stack[index].params[Effect.gaussianBlurRadiusKey]
                ?? EffectParam(value: staticBlurRadius)
            if mediaType == .text { param.value = nil }
            param.track = track
            stack[index].params[Effect.gaussianBlurRadiusKey] = param
        } else if let index = stack.firstIndex(where: { $0.type == Effect.gaussianBlurType }) {
            var param = stack[index].params[Effect.gaussianBlurRadiusKey] ?? EffectParam()
            param.track = nil
            stack[index].params[Effect.gaussianBlurRadiusKey] = param
            if mediaType == .text || (param.value ?? 0) == 0 {
                stack.remove(at: index)
            }
        }
        effects = stack.isEmpty ? nil : stack
    }

    mutating func upsertBlurKeyframe(frame: Int, value: Double) {
        var track = blurKeyframeTrack ?? KeyframeTrack<Double>()
        track.upsert(Keyframe(frame: frame - startFrame, value: value))
        setBlurKeyframeTrack(track)
    }

    private var gaussianBlurEffect: Effect? {
        effects?.first { $0.type == Effect.gaussianBlurType }
    }
}
