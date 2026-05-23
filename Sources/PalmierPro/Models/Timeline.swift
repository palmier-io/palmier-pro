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
    var label: String
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
        case id, type, label, muted, hidden, syncLocked, clips
    }
}

extension Track {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            type: try c.decode(ClipType.self, forKey: .type),
            label: try c.decode(String.self, forKey: .label),
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
    var audioFadeInFrames: Int = 0
    var audioFadeOutFrames: Int = 0
    var audioFadeInInterpolation: Interpolation = .smooth
    var audioFadeOutInterpolation: Interpolation = .smooth
    var opacity: Double = 1.0
    var transform: Transform = Transform()
    var crop: Crop = Crop()
    var linkGroupId: String?

    // Text clips only.
    var textContent: String?
    var textStyle: TextStyle?

    // Keyframe tracks for each animatable property. Nil when no animation exists.
    var opacityTrack: KeyframeTrack<Double>?
    var positionTrack: KeyframeTrack<AnimPair>?
    var scaleTrack: KeyframeTrack<AnimPair>?
    var cropTrack: KeyframeTrack<Crop>?
    var volumeTrack: KeyframeTrack<Double>?

    private enum CodingKeys: String, CodingKey {
        case id, mediaRef, mediaType, sourceClipType, startFrame, durationFrames
        case trimStartFrame, trimEndFrame, speed, volume
        case audioFadeInFrames, audioFadeOutFrames
        case audioFadeInInterpolation, audioFadeOutInterpolation
        case opacity, transform, crop
        case linkGroupId, textContent, textStyle
        case opacityTrack, positionTrack, scaleTrack, cropTrack, volumeTrack
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
        opacityTrack?.sample(at: keyframeOffset(forFrame: frame), fallback: opacity) ?? opacity
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
        return Transform(topLeft: (tl.x, tl.y), width: sz.width, height: sz.height)
    }

    var hasTransformAnimation: Bool {
        (positionTrack?.isActive ?? false) || (scaleTrack?.isActive ?? false)
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

    /// 0…1 fade multiplier from the head/tail ramps; 1 outside the fade regions.
    func fadeMultiplier(at frame: Int) -> Double {
        let rel = frame - startFrame
        guard rel >= 0, rel <= durationFrames else { return 0 }
        let inMul: Double = {
            guard audioFadeInFrames > 0 else { return 1.0 }
            let t = min(1.0, Double(rel) / Double(audioFadeInFrames))
            return audioFadeInInterpolation == .smooth ? smoothstep(t) : t
        }()
        let outRem = durationFrames - rel
        let outMul: Double = {
            guard audioFadeOutFrames > 0 else { return 1.0 }
            let t = min(1.0, Double(outRem) / Double(audioFadeOutFrames))
            return audioFadeOutInterpolation == .smooth ? smoothstep(t) : t
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
    /// Drops kfs past `durationFrames`. Call after any mutation that shrinks the clip.
    mutating func clampVolumeKfsToDuration() {
        guard var track = volumeTrack else { return }
        track.keyframes.removeAll { $0.frame < 0 || $0.frame > durationFrames }
        volumeTrack = track.keyframes.isEmpty ? nil : track
    }

    /// Clamp fade ramps so head + tail can't exceed the clip's duration.
    mutating func clampFadesToDuration() {
        audioFadeInFrames = max(0, min(audioFadeInFrames, durationFrames))
        audioFadeOutFrames = max(0, min(audioFadeOutFrames, durationFrames - audioFadeInFrames))
    }

    /// Set the fade length for one edge and clamp to fit. Centralizes the FadeEdge → field mapping.
    mutating func setFade(_ edge: FadeEdge, frames: Int) {
        switch edge {
        case .left:  audioFadeInFrames = max(0, frames)
        case .right: audioFadeOutFrames = max(0, frames)
        }
        clampFadesToDuration()
    }

    mutating func setFadeInterpolation(_ edge: FadeEdge, _ interpolation: Interpolation) {
        switch edge {
        case .left:  audioFadeInInterpolation = interpolation
        case .right: audioFadeOutInterpolation = interpolation
        }
    }

    mutating func setDuration(_ newDuration: Int) {
        durationFrames = newDuration
        clampVolumeKfsToDuration()
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
            audioFadeInFrames: (try? c.decode(Int.self, forKey: .audioFadeInFrames)) ?? 0,
            audioFadeOutFrames: (try? c.decode(Int.self, forKey: .audioFadeOutFrames)) ?? 0,
            audioFadeInInterpolation: (try? c.decode(Interpolation.self, forKey: .audioFadeInInterpolation)) ?? .smooth,
            audioFadeOutInterpolation: (try? c.decode(Interpolation.self, forKey: .audioFadeOutInterpolation)) ?? .smooth,
            opacity: (try? c.decode(Double.self, forKey: .opacity)) ?? 1.0,
            transform: (try? c.decode(Transform.self, forKey: .transform)) ?? Transform(),
            crop: (try? c.decode(Crop.self, forKey: .crop)) ?? Crop(),
            linkGroupId: try? c.decode(String.self, forKey: .linkGroupId),
            textContent: try? c.decode(String.self, forKey: .textContent),
            textStyle: try? c.decode(TextStyle.self, forKey: .textStyle),
            opacityTrack: try? c.decode(KeyframeTrack<Double>.self, forKey: .opacityTrack),
            positionTrack: try? c.decode(KeyframeTrack<AnimPair>.self, forKey: .positionTrack),
            scaleTrack: try? c.decode(KeyframeTrack<AnimPair>.self, forKey: .scaleTrack),
            cropTrack: try? c.decode(KeyframeTrack<Crop>.self, forKey: .cropTrack),
            volumeTrack: try? c.decode(KeyframeTrack<Double>.self, forKey: .volumeTrack)
        )
    }
}

struct Transform: Codable, Sendable, Equatable {
    var centerX: Double = 0.5
    var centerY: Double = 0.5
    var width: Double = 1
    var height: Double = 1
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
        flipHorizontal: Bool = false,
        flipVertical: Bool = false
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
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
        case centerX, centerY, width, height, flipHorizontal, flipVertical
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
        self.flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        self.flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(centerX, forKey: .centerX)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
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
