import Foundation

/// Clip location inside track storage.
struct ClipLocation: Equatable, Sendable {
    let trackIndex: Int
    let clipIndex: Int
}

struct Timeline: Codable, Sendable, Equatable {
    var fps: Int = 30
    var width: Int = 1920
    var height: Int = 1080
    var settingsConfigured: Bool = false
    var tracks: [Track] = []

    var totalFrames: Int {
        var maxFrame = 0
        for track in tracks {
            maxFrame = max(maxFrame, track.endFrame)
        }
        return maxFrame
    }
}

struct Track: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var type: ClipType
    var muted: Bool = false
    var hidden: Bool = false
    var syncLocked: Bool = true
    var clips: [Clip] = []

    /// Display-only height, not serialized. Reset to default on project open.
    var displayHeight: CGFloat = 50

    var endFrame: Int {
        var maxFrame = 0
        for clip in clips {
            maxFrame = max(maxFrame, clip.endFrame)
        }
        return maxFrame
    }

    /// Returns IDs of clips forming a contiguous chain starting at `fromEnd`, excluding `excludeId`.
    func contiguousClipIds(fromEnd: Int, excludeId: String) -> Set<String> {
        var ids = Set<String>()
        var chainEnd = fromEnd
        for c in clips.sorted(by: { $0.startFrame < $1.startFrame }) where c.id != excludeId && c.startFrame >= fromEnd {
            if c.startFrame != chainEnd { break }
            chainEnd = c.endFrame
            ids.insert(c.id)
        }
        return ids
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, muted, hidden, syncLocked, clips
    }
}

extension Track {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            type: try c.decode(ClipType.self, forKey: .type),
            muted: (try? c.decode(Bool.self, forKey: .muted)) ?? false,
            hidden: (try? c.decode(Bool.self, forKey: .hidden)) ?? false,
            syncLocked: (try? c.decode(Bool.self, forKey: .syncLocked)) ?? true,
            clips: (try? c.decode([Clip].self, forKey: .clips)) ?? []
        )
    }
}

struct Clip: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var mediaRef: String
    var mediaType: ClipType = .video
    // Original media type for derived clips; used for color-coding.
    var sourceClipType: ClipType = .video
    var startFrame: Int
    var durationFrames: Int
    var trimStartFrame: Int = 0
    var trimEndFrame: Int = 0
    var speed: Double = 1.0
    var volume: Double = 1.0
    var fadeInFrames: Int = 0
    var fadeOutFrames: Int = 0
    var fadeInInterpolation: Interpolation = .linear
    var fadeOutInterpolation: Interpolation = .linear
    var opacity: Double = 1.0
    var transform: Transform = Transform()
    var crop: Crop = Crop()
    var linkGroupId: String?
    var captionGroupId: String?

    // Text clips only.
    var textContent: String?
    var textStyle: TextStyle?

    // Keyframe tracks for each animatable property. Nil when no animation exists.
    var opacityTrack: KeyframeTrack<Double>?
    var positionTrack: KeyframeTrack<AnimPair>?
    var scaleTrack: KeyframeTrack<AnimPair>?
    var rotationTrack: KeyframeTrack<Double>?
    var cropTrack: KeyframeTrack<Crop>?
    var volumeTrack: KeyframeTrack<Double>?

    var effects: [Effect]?

    /// How this clip composites over the tracks below it. nil = normal (source-over).
    var blendMode: BlendMode?

    private enum CodingKeys: String, CodingKey {
        case id, mediaRef, mediaType, sourceClipType, startFrame, durationFrames
        case trimStartFrame, trimEndFrame, speed, volume
        case fadeInFrames, fadeOutFrames, fadeInInterpolation, fadeOutInterpolation
        case opacity, transform, crop
        case linkGroupId, captionGroupId, textContent, textStyle
        case opacityTrack, positionTrack, scaleTrack, rotationTrack, cropTrack, volumeTrack
        case effects, blendMode
    }

    /// Frame where this clip ends on the timeline
    var endFrame: Int { startFrame + durationFrames }

    /// Source frames consumed by the visible portion
    var sourceFramesConsumed: Int { Int((Double(durationFrames) * speed).rounded()) }

    /// Total source frames the clip references, including both trims.
    var sourceDurationFrames: Int { sourceFramesConsumed + trimStartFrame + trimEndFrame }

    /// Convert an absolute timeline frame to the clip-relative offset used by track storage.
    private func keyframeOffset(forFrame frame: Int) -> Int { frame - startFrame }

    func opacityAt(frame: Int) -> Double {
        let base = rawOpacityAt(frame: frame)
        guard mediaType != .audio, fadeInFrames > 0 || fadeOutFrames > 0 else { return base }
        return base * fadeMultiplier(at: frame)
    }

    /// Authored opacity without the fade envelope
    func rawOpacityAt(frame: Int) -> Double {
        opacityTrack?.sample(at: keyframeOffset(forFrame: frame), fallback: opacity) ?? opacity
    }

    func rotationAt(frame: Int) -> Double {
        rotationTrack?.sample(at: keyframeOffset(forFrame: frame), fallback: transform.rotation) ?? transform.rotation
    }

    /// Sampled topLeft (normalized canvas space) at `frame`
    func topLeftAt(frame: Int) -> (x: Double, y: Double) {
        if let track = positionTrack, track.isActive {
            let p = track.sample(at: keyframeOffset(forFrame: frame), fallback: AnimPair(a: 0, b: 0))
            return (p.a, p.b)
        }
        let c = transform.center
        let sz = sizeAt(frame: frame)
        return (c.x - sz.width / 2, c.y - sz.height / 2)
    }

    /// Sampled (width, height) at `frame`
    func sizeAt(frame: Int) -> (width: Double, height: Double) {
        let fallback = AnimPair(a: transform.width, b: transform.height)
        let s = scaleTrack?.sample(at: keyframeOffset(forFrame: frame), fallback: fallback) ?? fallback
        return (s.a, s.b)
    }

    /// Resolve the full Transform at `frame`
    func transformAt(frame: Int) -> Transform {
        let tl = topLeftAt(frame: frame)
        let sz = sizeAt(frame: frame)
        var t = Transform(topLeft: (tl.x, tl.y), width: sz.width, height: sz.height)
        t.rotation = rotationAt(frame: frame)
        return t
    }

    var hasTransformAnimation: Bool {
        (positionTrack?.isActive ?? false)
            || (scaleTrack?.isActive ?? false)
            || (rotationTrack?.isActive ?? false)
    }

    func cropAt(frame: Int) -> Crop {
        cropTrack?.sample(at: keyframeOffset(forFrame: frame), fallback: crop) ?? crop
    }

    func liveVolumeKfDb(at frame: Int) -> Double? {
        guard contains(timelineFrame: frame),
              let track = volumeTrack, track.isActive else { return nil }
        return track.sample(at: frame - startFrame, fallback: 0)
    }

    /// Effective linear volume at `frame`: keyframe envelope first, fade ramp on top, static volume as outer gain.
    func volumeAt(frame: Int) -> Double {
        let kfGain: Double
        if let track = volumeTrack, track.isActive {
            let dB = track.sample(at: keyframeOffset(forFrame: frame), fallback: 0)
            kfGain = VolumeScale.linearFromDb(dB)
        } else {
            kfGain = 1.0
        }
        return volume * kfGain * fadeMultiplier(at: frame)
    }

    func rawVolumeAt(frame: Int) -> Double {
        let kfGain: Double
        if let track = volumeTrack, track.isActive {
            kfGain = VolumeScale.linearFromDb(track.sample(at: keyframeOffset(forFrame: frame), fallback: 0))
        } else {
            kfGain = 1.0
        }
        return volume * kfGain
    }

    /// 0…1 envelope from the fade head/tail ramps.
    func fadeMultiplier(at frame: Int) -> Double {
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
    func timelineFrame(sourceSeconds t: Double, fps: Int) -> Int? {
        let sourceFrame = t * Double(fps)
        let offsetFromTrim = sourceFrame - Double(trimStartFrame)
        guard offsetFromTrim >= 0 else { return nil }
        let frame = Int((Double(startFrame) + offsetFromTrim / max(speed, 0.0001)).rounded())
        guard frame >= startFrame && frame < endFrame else { return nil }
        return frame
    }
}

enum FadeEdge { case left, right }

extension Clip {
    /// Drops volume keyframes outside `durationFrames`. Kept for callers that only touch volume.
    mutating func clampVolumeKfsToDuration() {
        volumeTrack = clampedKeyframeTrack(volumeTrack)
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
        durationFrames = newDuration
        clampKeyframesToDuration()
        clampFadesToDuration()
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
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
            linkGroupId: try? c.decode(String.self, forKey: .linkGroupId),
            captionGroupId: try? c.decode(String.self, forKey: .captionGroupId),
            textContent: try? c.decode(String.self, forKey: .textContent),
            textStyle: try? c.decode(TextStyle.self, forKey: .textStyle),
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

struct Transform: Codable, Sendable, Equatable {
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var width: Double = 1
    var height: Double = 1
    var rotation: Double = 0 // degrees, positive = clockwise
    var flipHorizontal: Bool = false
    var flipVertical: Bool = false

    var topLeft: (x: Double, y: Double) {
        (centerX - width / 2, centerY - height / 2)
    }

    var center: (x: Double, y: Double) {
        (centerX, centerY)
    }

    init(
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        width: Double = 1,
        height: Double = 1,
        rotation: Double = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    init(topLeft tl: (x: Double, y: Double), width w: Double, height h: Double) {
        self.centerX = tl.x + w / 2
        self.centerY = tl.y + h / 2
        self.width = w
        self.height = h
    }

    init(center c: (x: Double, y: Double), width w: Double, height h: Double) {
        self.centerX = c.x
        self.centerY = c.y
        self.width = w
        self.height = h
    }

    private enum CodingKeys: String, CodingKey {
        case centerX, centerY, width, height, rotation, flipHorizontal, flipVertical
        // Legacy keys
        case x, y
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let w = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1
        let h = try c.decodeIfPresent(Double.self, forKey: .height) ?? 1
        if let cx = try c.decodeIfPresent(Double.self, forKey: .centerX) {
            self.centerX = cx
        } else if let oldX = try c.decodeIfPresent(Double.self, forKey: .x) {
            self.centerX = oldX + w - 0.5
        } else {
            self.centerX = 0.5
        }
        if let cy = try c.decodeIfPresent(Double.self, forKey: .centerY) {
            self.centerY = cy
        } else if let oldY = try c.decodeIfPresent(Double.self, forKey: .y) {
            self.centerY = oldY + h - 0.5
        } else {
            self.centerY = 0.5
        }
        self.width = w
        self.height = h
        self.rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        self.flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        self.flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(centerX, forKey: .centerX)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(flipHorizontal, forKey: .flipHorizontal)
        try c.encode(flipVertical, forKey: .flipVertical)
    }

    /// Snap a value to canvas boundaries (0 or 1) within threshold.
    static func snapToBoundary(_ value: Double, threshold: Double) -> Double {
        if abs(value) < threshold { return 0 }
        if abs(value - 1) < threshold { return 1 }
        return value
    }

    /// Snap clip edges to canvas boundaries (0 or 1).
    mutating func snapToCanvasEdges(threshold: Double) {
        let tl = topLeft
        let snappedLeft = Self.snapToBoundary(tl.x, threshold: threshold)
        let snappedRight = Self.snapToBoundary(tl.x + width, threshold: threshold)
        if snappedLeft != tl.x {
            centerX -= (tl.x - snappedLeft)
        } else if snappedRight != tl.x + width {
            centerX -= (tl.x + width - snappedRight)
        }

        let tl2 = topLeft
        let snappedTop = Self.snapToBoundary(tl2.y, threshold: threshold)
        let snappedBottom = Self.snapToBoundary(tl2.y + height, threshold: threshold)
        if snappedTop != tl2.y {
            centerY -= (tl2.y - snappedTop)
        } else if snappedBottom != tl2.y + height {
            centerY -= (tl2.y + height - snappedBottom)
        }
    }

    /// Snap per-axis within threshold. Return tuple lets callers draw guide indicators.
    @discardableResult
    mutating func snapCenterToCanvasCenter(thresholdH: Double, thresholdV: Double) -> (x: Bool, y: Bool) {
        var snappedX = false
        var snappedY = false
        if abs(centerX - 0.5) < thresholdH {
            centerX = 0.5
            snappedX = true
        }
        if abs(centerY - 0.5) < thresholdV {
            centerY = 0.5
            snappedY = true
        }
        return (snappedX, snappedY)
    }
}

/// Per-clip crop as edge insets in normalized (0–1) source coordinates.
struct Crop: Codable, Sendable, Equatable {
    var left: Double = 0
    var top: Double = 0
    var right: Double = 0
    var bottom: Double = 0

    var isIdentity: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
    var visibleWidthFraction: Double { max(0, 1 - left - right) }
    var visibleHeightFraction: Double { max(0, 1 - top - bottom) }
}

/// Aspect-ratio constraint for the Crop overlay.
enum CropAspectLock: Hashable, CaseIterable {
    case free, original, r16x9, r9x16, r1x1, r4x3, r3x4, r21x9

    var label: String {
        switch self {
        case .free: "Custom"
        case .original: "Original"
        case .r16x9: "16:9"
        case .r9x16: "9:16"
        case .r1x1: "1:1"
        case .r4x3: "4:3"
        case .r3x4: "3:4"
        case .r21x9: "21:9"
        }
    }

    var pixelAspect: Double? {
        switch self {
        case .free, .original: nil
        case .r16x9: 16.0 / 9.0
        case .r9x16: 9.0 / 16.0
        case .r1x1: 1.0
        case .r4x3: 4.0 / 3.0
        case .r3x4: 3.0 / 4.0
        case .r21x9: 21.0 / 9.0
        }
    }
}
