import Foundation

public struct Clip: Codable, Sendable, Equatable, Identifiable {
    public var id: String = UUID().uuidString
    public var mediaRef: String
    public var mediaType: ClipType = .video
    // Original media type for derived clips; used for color-coding.
    public var sourceClipType: ClipType = .video
    public var startFrame: Int
    public var durationFrames: Int
    public var trimStartFrame: Int = 0
    public var trimEndFrame: Int = 0
    public var speed: Double = 1.0
    public var volume: Double = 1.0
    public var fadeInFrames: Int = 0
    public var fadeOutFrames: Int = 0
    public var fadeInInterpolation: Interpolation = .linear
    public var fadeOutInterpolation: Interpolation = .linear
    public var opacity: Double = 1.0
    public var transform: Transform = Transform()
    public var crop: Crop = Crop()
    public var edgeRounding: Double = 0
    public var edgeSoftness: Double = 0
    public var linkGroupId: String?
    public var captionGroupId: String?
    public var multicamGroupId: String?

    // Text clips only.
    public var textContent: String?
    public var textStyle: TextStyle?
    public var textAnimation: TextAnimation?
    public var wordTimings: [WordTiming]?
    public var textFillMode: TextFillMode?

    // Keyframe tracks for each animatable property. Nil when no animation exists.
    public var opacityTrack: KeyframeTrack<Double>?
    public var positionTrack: KeyframeTrack<AnimPair>?
    public var scaleTrack: KeyframeTrack<AnimPair>?
    public var rotationTrack: KeyframeTrack<Double>?
    public var cropTrack: KeyframeTrack<Crop>?
    public var volumeTrack: KeyframeTrack<Double>?

    public var effects: [Effect]?

    /// How this clip composites over the tracks below it. nil = normal (source-over).
    public var blendMode: BlendMode?

    public init(mediaRef: String, startFrame: Int, durationFrames: Int) {
        self.mediaRef = mediaRef
        self.startFrame = startFrame
        self.durationFrames = durationFrames
    }

    private enum CodingKeys: String, CodingKey {
        case id, mediaRef, mediaType, sourceClipType, startFrame, durationFrames
        case trimStartFrame, trimEndFrame, speed, volume
        case fadeInFrames, fadeOutFrames, fadeInInterpolation, fadeOutInterpolation
        case opacity, transform, crop, edgeRounding, edgeSoftness
        case linkGroupId, captionGroupId, multicamGroupId, textContent, textStyle, textAnimation, wordTimings
        case textFillMode
        case opacityTrack, positionTrack, scaleTrack, rotationTrack, cropTrack, volumeTrack
        case effects, blendMode
    }

    /// Frame where this clip ends on the timeline
    public var endFrame: Int { startFrame + durationFrames }

    public var supportsRetiming: Bool { sourceClipType != .sequence }

    /// Source frames consumed by the visible portion
    public var sourceFramesConsumed: Int { Int((Double(durationFrames) * speed).rounded()) }

    /// Total source frames the clip references, including both trims.
    public var sourceDurationFrames: Int { sourceFramesConsumed + trimStartFrame + trimEndFrame }

    /// Convert an absolute timeline frame to the clip-relative offset used by track storage.
    private func keyframeOffset(forFrame frame: Int) -> Int { frame - startFrame }

    public func opacityAt(frame: Int) -> Double {
        let base = rawOpacityAt(frame: frame)
        guard mediaType != .audio, fadeInFrames > 0 || fadeOutFrames > 0 else { return base }
        return base * fadeMultiplier(at: frame)
    }

    /// Authored opacity without the fade envelope
    public func rawOpacityAt(frame: Int) -> Double {
        opacityTrack?.sample(at: keyframeOffset(forFrame: frame), fallback: opacity) ?? opacity
    }

    public func rotationAt(frame: Int) -> Double {
        rotationTrack?.sample(at: keyframeOffset(forFrame: frame), fallback: transform.rotation) ?? transform.rotation
    }

    /// Sampled topLeft (normalized canvas space) at `frame`
    public func topLeftAt(frame: Int) -> (x: Double, y: Double) {
        if let track = positionTrack, track.isActive {
            let p = track.sample(at: keyframeOffset(forFrame: frame), fallback: AnimPair(a: 0, b: 0))
            return (p.a, p.b)
        }
        let c = transform.center
        let sz = sizeAt(frame: frame)
        return (c.x - sz.width / 2, c.y - sz.height / 2)
    }

    /// Sampled (width, height) at `frame`
    public func sizeAt(frame: Int) -> (width: Double, height: Double) {
        let fallback = AnimPair(a: transform.width, b: transform.height)
        let s = scaleTrack?.sample(at: keyframeOffset(forFrame: frame), fallback: fallback) ?? fallback
        return (s.a, s.b)
    }

    /// Resolve the full Transform at `frame`
    public func transformAt(frame: Int) -> Transform {
        let tl = topLeftAt(frame: frame)
        let sz = sizeAt(frame: frame)
        var t = transform
        t.centerX = tl.x + sz.width / 2
        t.centerY = tl.y + sz.height / 2
        t.width = sz.width
        t.height = sz.height
        t.rotation = rotationAt(frame: frame)
        return t
    }

    public var hasTransformAnimation: Bool {
        (positionTrack?.isActive ?? false)
            || (scaleTrack?.isActive ?? false)
            || (rotationTrack?.isActive ?? false)
    }

    public func cropAt(frame: Int) -> Crop {
        cropTrack?.sample(at: keyframeOffset(forFrame: frame), fallback: crop) ?? crop
    }

    public func liveVolumeKfDb(at frame: Int) -> Double? {
        guard contains(timelineFrame: frame),
              let track = volumeTrack, track.isActive else { return nil }
        return track.sample(at: frame - startFrame, fallback: 0)
    }

    /// True when `frame` falls within `[startFrame, endFrame)`.
    public func contains(timelineFrame frame: Int) -> Bool {
        frame >= startFrame && frame < endFrame
    }

    /// Effective linear volume at `frame`: keyframe envelope first, fade ramp on top, static volume as outer gain.
    public func volumeAt(frame: Int) -> Double {
        let kfGain: Double
        if let track = volumeTrack, track.isActive {
            let dB = track.sample(at: keyframeOffset(forFrame: frame), fallback: 0)
            kfGain = VolumeScale.linearFromDb(dB)
        } else {
            kfGain = 1.0
        }
        return volume * kfGain * fadeMultiplier(at: frame)
    }

    public var hasDenoiseEnabled: Bool {
        effects?.contains { $0.type == Clip.denoiseEffectType && $0.enabled } ?? false
    }

    public var denoiseAmount: Double {
        effects?.first { $0.type == Clip.denoiseEffectType }?.params["amount"]?.value ?? Clip.defaultDenoiseAmount
    }

    public static let denoiseEffectType = "audio.denoise"
    public static let defaultDenoiseAmount: Double = 0.6

    public func rawVolumeAt(frame: Int) -> Double {
        let kfGain: Double
        if let track = volumeTrack, track.isActive {
            kfGain = VolumeScale.linearFromDb(track.sample(at: keyframeOffset(forFrame: frame), fallback: 0))
        } else {
            kfGain = 1.0
        }
        return volume * kfGain
    }

    /// 0…1 envelope from the fade head/tail ramps.
    public func fadeMultiplier(at frame: Int) -> Double {
        let rel = frame - startFrame
        guard rel >= 0, rel <= durationFrames else { return 0 }
        let inMul: Double = {
            guard fadeInFrames > 0 else { return 1.0 }
            let t = min(1.0, Double(rel) / Double(fadeInFrames))
            return fadeInInterpolation == .smooth ? smoothstep(t) : t
        }()
        let outRem = durationFrames - rel
        let outMul: Double = {
            guard fadeOutFrames > 0 else { return 1.0 }
            let t = min(1.0, Double(outRem) / Double(fadeOutFrames))
            return fadeOutInterpolation == .smooth ? smoothstep(t) : t
        }()
        return min(inMul, outMul)
    }

    /// Source-seconds → project-timeline-frame through this clip's placement, trim, and speed.
    public func timelineFrame(sourceSeconds t: Double, fps: Int) -> Int? {
        let sourceFrame = t * Double(fps)
        let offsetFromTrim = sourceFrame - Double(trimStartFrame)
        guard offsetFromTrim >= 0 else { return nil }
        let frame = Int((Double(startFrame) + offsetFromTrim / max(speed, 0.0001)).rounded())
        guard frame >= startFrame && frame < endFrame else { return nil }
        return frame
    }
}

public enum FadeEdge { case left, right }

public extension Clip {
    /// Fresh clip id; link/caption group ids remapped consistently via `groups`.
    mutating func freshenIds(groups: inout [String: String]) {
        func remap(_ old: String?) -> String? {
            guard let old else { return nil }
            if let new = groups[old] { return new }
            let new = UUID().uuidString
            groups[old] = new
            return new
        }
        id = UUID().uuidString
        linkGroupId = remap(linkGroupId)
        captionGroupId = remap(captionGroupId)
    }

    /// Drops kfs past `durationFrames`. Call after any mutation that shrinks the clip.
    mutating func clampKeyframesToDuration() {
        opacityTrack = clampedKeyframeTrack(opacityTrack)
        positionTrack = clampedKeyframeTrack(positionTrack)
        scaleTrack = clampedKeyframeTrack(scaleTrack)
        rotationTrack = clampedKeyframeTrack(rotationTrack)
        cropTrack = clampedKeyframeTrack(cropTrack)
        volumeTrack = clampedKeyframeTrack(volumeTrack)
    }

    mutating func rescaleKeyframes(by scale: Double) {
        opacityTrack = rescaledKeyframeTrack(opacityTrack, by: scale)
        positionTrack = rescaledKeyframeTrack(positionTrack, by: scale)
        scaleTrack = rescaledKeyframeTrack(scaleTrack, by: scale)
        rotationTrack = rescaledKeyframeTrack(rotationTrack, by: scale)
        cropTrack = rescaledKeyframeTrack(cropTrack, by: scale)
        volumeTrack = rescaledKeyframeTrack(volumeTrack, by: scale)
    }

    private func clampedKeyframeTrack<V: Codable & Sendable & Equatable>(
        _ track: KeyframeTrack<V>?
    ) -> KeyframeTrack<V>? {
        guard var track else { return nil }
        var normalized = KeyframeTrack<V>()
        for kf in track.keyframes where kf.frame >= 0 && kf.frame <= durationFrames {
            normalized.upsert(kf)
        }
        track.keyframes = normalized.keyframes
        return track.keyframes.isEmpty ? nil : track
    }

    private func rescaledKeyframeTrack<V: Codable & Sendable & Equatable>(
        _ track: KeyframeTrack<V>?,
        by scale: Double
    ) -> KeyframeTrack<V>? {
        guard let existing = track else { return nil }
        guard scale.isFinite, scale > 0 else { return existing }
        var normalized = KeyframeTrack<V>()
        for kf in existing.keyframes {
            var next = kf
            next.frame = Int((Double(kf.frame) * scale).rounded())
            normalized.upsert(next)
        }
        return normalized.keyframes.isEmpty ? nil : normalized
    }

    /// Clamp fade ramps so head + tail can't exceed the clip's duration.
    mutating func clampFadesToDuration() {
        fadeInFrames = max(0, min(fadeInFrames, durationFrames))
        fadeOutFrames = max(0, min(fadeOutFrames, durationFrames - fadeInFrames))
    }

    mutating func rescaleWordTimings(from oldDuration: Int) {
        guard mediaType == .text, let timings = wordTimings, oldDuration > 0, durationFrames > 0 else { return }
        let scale = Double(durationFrames) / Double(oldDuration)
        wordTimings = timings.map { timing in
            let start = min(max(0, Int((Double(timing.startFrame) * scale).rounded())), max(0, durationFrames - 1))
            let end = min(max(start + 1, Int((Double(timing.endFrame) * scale).rounded())), durationFrames)
            return WordTiming(text: timing.text, startFrame: start, endFrame: end)
        }
    }

    /// Set the fade length for one edge and clamp to fit.
    mutating func setFade(_ edge: FadeEdge, frames: Int) {
        let v = max(0, frames)
        switch edge {
        case .left:  fadeInFrames  = v
        case .right: fadeOutFrames = v
        }
        clampFadesToDuration()
    }

    mutating func setFadeInterpolation(_ edge: FadeEdge, _ interpolation: Interpolation) {
        switch edge {
        case .left:  fadeInInterpolation  = interpolation
        case .right: fadeOutInterpolation = interpolation
        }
    }

    func fadeFrames(_ edge: FadeEdge) -> Int {
        edge == .left ? fadeInFrames : fadeOutFrames
    }

    func fadeInterpolation(_ edge: FadeEdge) -> Interpolation {
        edge == .left ? fadeInInterpolation : fadeOutInterpolation
    }

    mutating func setDuration(_ newDuration: Int) {
        let oldDuration = durationFrames
        durationFrames = newDuration
        rescaleWordTimings(from: oldDuration)
        clampKeyframesToDuration()
        clampFadesToDuration()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func normalizedValue(forKey key: CodingKeys) -> Double {
            let value = (try? c.decode(Double.self, forKey: key)) ?? 0
            return (0...1).contains(value) ? value : 0
        }
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            mediaRef: try c.decode(String.self, forKey: .mediaRef),
            mediaType: (try? c.decode(ClipType.self, forKey: .mediaType)) ?? .video,
            sourceClipType: (try? c.decode(ClipType.self, forKey: .sourceClipType)) ?? .video,
            startFrame: try c.decode(Int.self, forKey: .startFrame),
            durationFrames: try c.decode(Int.self, forKey: .durationFrames),
            trimStartFrame: (try? c.decode(Int.self, forKey: .trimStartFrame)) ?? 0,
            trimEndFrame: (try? c.decode(Int.self, forKey: .trimEndFrame)) ?? 0,
            speed: (try? c.decode(Double.self, forKey: .speed)) ?? 1.0,
            volume: (try? c.decode(Double.self, forKey: .volume)) ?? 1.0,
            fadeInFrames: (try? c.decode(Int.self, forKey: .fadeInFrames)) ?? 0,
            fadeOutFrames: (try? c.decode(Int.self, forKey: .fadeOutFrames)) ?? 0,
            fadeInInterpolation: (try? c.decode(Interpolation.self, forKey: .fadeInInterpolation)) ?? .linear,
            fadeOutInterpolation: (try? c.decode(Interpolation.self, forKey: .fadeOutInterpolation)) ?? .linear,
            opacity: (try? c.decode(Double.self, forKey: .opacity)) ?? 1.0,
            transform: (try? c.decode(Transform.self, forKey: .transform)) ?? Transform(),
            crop: (try? c.decode(Crop.self, forKey: .crop)) ?? Crop(),
            edgeRounding: normalizedValue(forKey: .edgeRounding),
            edgeSoftness: normalizedValue(forKey: .edgeSoftness),
            linkGroupId: try? c.decode(String.self, forKey: .linkGroupId),
            captionGroupId: try? c.decode(String.self, forKey: .captionGroupId),
            multicamGroupId: try? c.decode(String.self, forKey: .multicamGroupId),
            textContent: try? c.decode(String.self, forKey: .textContent),
            textStyle: try? c.decode(TextStyle.self, forKey: .textStyle),
            textAnimation: try? c.decode(TextAnimation.self, forKey: .textAnimation),
            wordTimings: try? c.decode([WordTiming].self, forKey: .wordTimings),
            textFillMode: try? c.decode(TextFillMode.self, forKey: .textFillMode),
            opacityTrack: try? c.decode(KeyframeTrack<Double>.self, forKey: .opacityTrack),
            positionTrack: try? c.decode(KeyframeTrack<AnimPair>.self, forKey: .positionTrack),
            scaleTrack: try? c.decode(KeyframeTrack<AnimPair>.self, forKey: .scaleTrack),
            rotationTrack: try? c.decode(KeyframeTrack<Double>.self, forKey: .rotationTrack),
            cropTrack: try? c.decode(KeyframeTrack<Crop>.self, forKey: .cropTrack),
            volumeTrack: try? c.decode(KeyframeTrack<Double>.self, forKey: .volumeTrack),
            effects: try? c.decode([Effect].self, forKey: .effects),
            blendMode: try? c.decode(BlendMode.self, forKey: .blendMode)
        )
    }
}

extension Clip {
    /// Memberwise initializer exposing every stored property with defaults.
    /// The synthesized memberwise init is internal; this public form keeps app
    /// code that constructs clips with all fields working after the move.
    public init(
        id: String = UUID().uuidString,
        mediaRef: String,
        mediaType: ClipType = .video,
        sourceClipType: ClipType = .video,
        startFrame: Int,
        durationFrames: Int,
        trimStartFrame: Int = 0,
        trimEndFrame: Int = 0,
        speed: Double = 1.0,
        volume: Double = 1.0,
        fadeInFrames: Int = 0,
        fadeOutFrames: Int = 0,
        fadeInInterpolation: Interpolation = .linear,
        fadeOutInterpolation: Interpolation = .linear,
        opacity: Double = 1.0,
        transform: Transform = Transform(),
        crop: Crop = Crop(),
        edgeRounding: Double = 0,
        edgeSoftness: Double = 0,
        linkGroupId: String? = nil,
        captionGroupId: String? = nil,
        multicamGroupId: String? = nil,
        textContent: String? = nil,
        textStyle: TextStyle? = nil,
        textAnimation: TextAnimation? = nil,
        wordTimings: [WordTiming]? = nil,
        textFillMode: TextFillMode? = nil,
        opacityTrack: KeyframeTrack<Double>? = nil,
        positionTrack: KeyframeTrack<AnimPair>? = nil,
        scaleTrack: KeyframeTrack<AnimPair>? = nil,
        rotationTrack: KeyframeTrack<Double>? = nil,
        cropTrack: KeyframeTrack<Crop>? = nil,
        volumeTrack: KeyframeTrack<Double>? = nil,
        effects: [Effect]? = nil,
        blendMode: BlendMode? = nil
    ) {
        self.id = id
        self.mediaRef = mediaRef
        self.mediaType = mediaType
        self.sourceClipType = sourceClipType
        self.startFrame = startFrame
        self.durationFrames = durationFrames
        self.trimStartFrame = trimStartFrame
        self.trimEndFrame = trimEndFrame
        self.speed = speed
        self.volume = volume
        self.fadeInFrames = fadeInFrames
        self.fadeOutFrames = fadeOutFrames
        self.fadeInInterpolation = fadeInInterpolation
        self.fadeOutInterpolation = fadeOutInterpolation
        self.opacity = opacity
        self.transform = transform
        self.crop = crop
        self.edgeRounding = edgeRounding
        self.edgeSoftness = edgeSoftness
        self.linkGroupId = linkGroupId
        self.captionGroupId = captionGroupId
        self.multicamGroupId = multicamGroupId
        self.textContent = textContent
        self.textStyle = textStyle
        self.textAnimation = textAnimation
        self.wordTimings = wordTimings
        self.textFillMode = textFillMode
        self.opacityTrack = opacityTrack
        self.positionTrack = positionTrack
        self.scaleTrack = scaleTrack
        self.rotationTrack = rotationTrack
        self.cropTrack = cropTrack
        self.volumeTrack = volumeTrack
        self.effects = effects
        self.blendMode = blendMode
    }
}
