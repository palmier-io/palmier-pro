import Foundation

extension ToolExecutor {
    private struct ImportAnimationAdapterInput: DecodableToolArgs {
        let format: String
        let source: AnimationSourceInput
        let targetFPS: Int?
        let targetDurationFrames: Int?
        let targetProperties: [String]?
        let applyToClipId: String?
        let trackIndex: Int?
        let clipId: String?

        static let allowedKeys: Set<String> = [
            "format", "source", "targetFPS", "targetDurationFrames",
            "targetProperties", "applyToClipId", "trackIndex", "clipId"
        ]
    }

    private struct AnimationSourceInput: Decodable {
        let type: String
        let jsonString: String?
        let filePath: String?
    }

    /// Import a web animation (GSAP, Lottie, CSS) and convert to native keyframe tracks.
    func importAnimationAdapter(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try Task.checkCancellation()
        let input: ImportAnimationAdapterInput = try decodeToolArgs(args, path: "import_animation_adapter")

        guard let format = AnimationFormat(rawValue: input.format.lowercased()) else {
            let options = AnimationFormat.allCases.map(\.rawValue).joined(separator: ", ")
            throw ToolError("format must be one of: \(options)")
        }

        let targetFPS = input.targetFPS ?? editor.timeline.fps
        let targetDurationFrames = input.targetDurationFrames
        let targetProperties = input.targetProperties?.compactMap { NativeKeyframeProperty(rawValue: $0.lowercased()) }

        let source: AnimationSource
        switch input.source.type {
        case "jsonString":
            guard let json = input.source.jsonString else { throw ToolError("source.jsonString required for type jsonString") }
            source = .jsonString(json)
        case "fileURL":
            guard let path = input.source.filePath else { throw ToolError("source.filePath required for type fileURL") }
            source = .fileURL(URL(fileURLWithPath: path))
        default:
            throw ToolError("source.type must be 'jsonString' or 'fileURL'")
        }

        let adapterInput = AnimationAdapterInput(
            format: format,
            source: source,
            targetFPS: targetFPS,
            targetDurationFrames: targetDurationFrames,
            targetProperties: targetProperties
        )

        let adapted = try await AnimationAdapter.shared.adapt(adapterInput)

        // Optionally apply to a clip
        var appliedClipId: String?
        if let applyId = input.applyToClipId ?? input.clipId {
            guard var clip = editor.clipFor(id: applyId) else {
                throw ToolError("Clip not found: \(applyId)")
            }
            for anim in adapted {
                applyAdaptedAnimation(&clip, animation: anim)
            }
            editor.replaceClip(clip, trackIndex: input.trackIndex)
            appliedClipId = clip.id
        }

        let animationsJSON = adapted.map { anim in
            [
                "property": anim.property.rawValue,
                "durationFrames": anim.durationFrames,
                "fps": anim.fps,
                "keyframeCount": anim.keyframes.count,
                "keyframes": anim.keyframes.map { kf in
                    [
                        "frame": kf.frame,
                        "value": encodeAdaptedValue(kf.value),
                        "interpolation": kf.interpolation.rawValue
                    ]
                }
            ]
        }

        return .ok(Self.jsonString([
            "status": "ok",
            "animations": animationsJSON,
            "appliedClipId": appliedClipId as Any,
            "message": "Adapted \(adapted.count) animation property(ies) from \(format.rawValue)."
        ]) ?? "{}")
    }

    private func applyAdaptedAnimation(_ clip: inout Clip, animation: AdaptedAnimation) {
        var track: KeyframeTrack<AnimPair>?
        var opacityTrack: KeyframeTrack<Double>?
        var rotationTrack: KeyframeTrack<Double>?

        for kf in animation.keyframes {
            let frame = kf.frame
            let interp = mapInterpolation(kf.interpolation)

            switch animation.property {
            case .position:
                if case .point(let x, let y) = kf.value {
                    var t = track ?? KeyframeTrack<AnimPair>()
                    t.keyframes.append(Keyframe(frame: frame, value: AnimPair(a: x, b: y), interpolationOut: interp))
                    track = t
                }
            case .scale:
                if case .size(let w, let h) = kf.value {
                    var t = track ?? KeyframeTrack<AnimPair>()
                    t.keyframes.append(Keyframe(frame: frame, value: AnimPair(a: w, b: h), interpolationOut: interp))
                    track = t
                }
            case .opacity:
                if case .scalar(let v) = kf.value {
                    var t = opacityTrack ?? KeyframeTrack<Double>()
                    t.keyframes.append(Keyframe(frame: frame, value: v, interpolationOut: interp))
                    opacityTrack = t
                }
            case .rotation:
                if case .scalar(let v) = kf.value {
                    var t = rotationTrack ?? KeyframeTrack<Double>()
                    t.keyframes.append(Keyframe(frame: frame, value: v, interpolationOut: interp))
                    rotationTrack = t
                }
            }
        }

        switch animation.property {
        case .position: clip.positionTrack = track
        case .scale: clip.scaleTrack = track
        case .opacity: clip.opacityTrack = opacityTrack
        case .rotation: clip.rotationTrack = rotationTrack
        }
    }

    private func mapInterpolation(_ type: InterpolationType) -> Interpolation {
        switch type {
        case .linear: return .linear
        case .easeIn, .easeOut, .easeInOut: return .smooth
        case .smooth: return .smooth
        case .hold: return .hold
        }
    }

    private func encodeAdaptedValue(_ value: AdaptedValue) -> [String: Any] {
        switch value {
        case .scalar(let v): return ["type": "scalar", "value": v]
        case .point(let x, let y): return ["type": "point", "x": x, "y": y]
        case .size(let w, let h): return ["type": "size", "width": w, "height": h]
        case .color(let r, let g, let b, let a): return ["type": "color", "r": r, "g": g, "b": b, "a": a]
        }
    }
}