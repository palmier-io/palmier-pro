import Foundation

/// Clip location inside track storage.
struct ClipLocation: Equatable, Sendable {
    let trackIndex: Int
    let clipIndex: Int
}

/// Written on tab switch and save, not live — playhead mutates every frame.
struct TimelineViewState: Codable, Sendable, Equatable {
    var playheadFrame: Int = 0
    var zoomScale: Double = Defaults.pixelsPerFrame
    var scrollOffsetX: Double = 0
}

struct Timeline: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var name: String = "Timeline 1"
    var fps: Int = 30
    var width: Int = 1920
    var height: Int = 1080
    var settingsConfigured: Bool = false
    var folderId: String?
    var tracks: [Track] = []

    var totalFrames: Int {
        var maxFrame = 0
        for track in tracks {
            maxFrame = max(maxFrame, track.endFrame)
        }
        return maxFrame
    }

    var hasAudioClips: Bool {
        tracks.contains { $0.type == .audio && !$0.clips.isEmpty }
    }

    /// Reachable nested timelines, breadth-first, deduped, excluding self and filtered by `include`.
    func reachableTimelines(
        resolve: (String) -> Timeline?,
        maxDepth: Int = Int.max,
        include: (Timeline) -> Bool = { _ in true }
    ) -> [Timeline] {
        var found: [Timeline] = []
        var seen: Set<String> = [id]
        var queue: [(t: Timeline, depth: Int)] = [(self, 0)]
        var i = 0
        while i < queue.count {
            let (t, depth) = queue[i]
            i += 1
            guard depth < maxDepth else { continue }
            for clip in t.tracks.flatMap(\.clips) where clip.sourceClipType == .sequence {
                guard seen.insert(clip.mediaRef).inserted,
                      let child = resolve(clip.mediaRef), include(child) else { continue }
                found.append(child)
                queue.append((child, depth + 1))
            }
        }
        return found
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, fps, width, height, settingsConfigured, folderId, tracks
    }
}

extension Timeline {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString,
            name: (try? c.decode(String.self, forKey: .name)) ?? "Timeline 1",
            fps: try c.decode(Int.self, forKey: .fps),
            width: try c.decode(Int.self, forKey: .width),
            height: try c.decode(Int.self, forKey: .height),
            settingsConfigured: (try? c.decode(Bool.self, forKey: .settingsConfigured)) ?? false,
            folderId: try? c.decode(String.self, forKey: .folderId),
            tracks: try c.decode([Track].self, forKey: .tracks)
        )
    }
}

struct Track: Codable, Sendable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var type: ClipType
    var muted: Bool = false
    var hidden: Bool = false
    var syncLocked: Bool = true
    var clips: [Clip] = []

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
        case id, type, muted, hidden, syncLocked, clips, displayHeight
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
            clips: (try? c.decode([Clip].self, forKey: .clips)) ?? [],
            displayHeight: (try? c.decode(CGFloat.self, forKey: .displayHeight))
                .map { min(max($0, TrackSize.minHeight), TrackSize.maxHeight) } ?? 50
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
    var edgeRounding: Double = 0
    var edgeSoftness: Double = 0
    var linkGroupId: String?
    var captionGroupId: String?
    var multicamGroupId: String?

    // Text clips only.
    var textContent: String?
    var textStyle: TextStyle?
    var textAnimation: TextAnimation?
    var wordTimings: [WordTiming]?
    var textFillMode: TextFillMode?

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
        case opacity, transform, crop, edgeRounding, edgeSoftness
        case linkGroupId, captionGroupId, multicamGroupId, textContent, textStyle, textAnimation, wordTimings
        case textFillMode
        case opacityTrack, positionTrack, scaleTrack, rotationTrack, cropTrack, volumeTrack
        case effects, blendMode
    }

    /// Frame where this clip ends on the timeline
    var endFrame: Int { startFrame + durationFrames }

    var supportsRetiming: Bool { sourceClipType != .sequence }

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
        var t = transform
        t.centerX = tl.x + sz.width / 2
        t.centerY = tl.y + sz.height / 2
        t.width = sz.width
        t.height = sz.height
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

    var hasDenoiseEnabled: Bool {
        effects?.contains { $0.type == Clip.denoiseEffectType && $0.enabled } ?? false
    }

    var denoiseAmount: Double {
        effects?.first { $0.type == Clip.denoiseEffectType }?.params["amount"]?.value ?? Clip.defaultDenoiseAmount
    }

    static let denoiseEffectType = "audio.denoise"
    static let defaultDenoiseAmount: Double = 0.6

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

// Transform, Crop, and CropAspectLock live in PalmierCore (Transform.swift)
// and are re-exported via @_exported import PalmierCore.
