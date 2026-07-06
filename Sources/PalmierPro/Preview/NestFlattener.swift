import CoreGraphics
import Foundation

/// Expands a nest carrier one level: child clips remapped into parent frames.
enum NestFlattener {
    static let maxDepth = 8

    struct Flattened: Sendable {
        /// Child visual tracks, child track order preserved (text clips included).
        var videoTracks: [[Clip]] = []
        /// Unmuted child audio tracks; clips within a track never overlap.
        var audioTracks: [[Clip]] = []
        var childCanvas: CGSize = .zero
    }

    /// `carrier` = the video `.sequence` clip or its linked audio clip.
    static func flatten(carrier: Clip, child: Timeline, visual: Bool) -> Flattened {
        var out = Flattened()
        out.childCanvas = CGSize(width: child.width, height: child.height)
        let window = carrier.trimStartFrame..<(carrier.trimStartFrame + carrier.durationFrames)
        let shift = carrier.startFrame - carrier.trimStartFrame

        for track in child.tracks {
            if visual {
                guard track.type == .video, !track.hidden else { continue }
                let clips = track.clips
                    .sorted { $0.startFrame < $1.startFrame }
                    .compactMap { remap($0, window: window, shift: shift, nestId: carrier.id) }
                if !clips.isEmpty { out.videoTracks.append(clips) }
            } else {
                guard track.type == .audio, !track.muted else { continue }
                let clips = track.clips
                    .sorted { $0.startFrame < $1.startFrame }
                    .compactMap { remap($0, window: window, shift: shift, nestId: carrier.id) }
                if !clips.isEmpty { out.audioTracks.append(clips) }
            }
        }
        return out
    }

    private static func remap(_ clip: Clip, window: Range<Int>, shift: Int, nestId: String) -> Clip? {
        let start = max(clip.startFrame, window.lowerBound)
        let end = min(clip.endFrame, window.upperBound)
        guard end > start else { return nil }

        var c = clip
        let headCut = start - clip.startFrame
        if headCut > 0 {
            c.trimStartFrame += Int((Double(headCut) * c.speed).rounded())
            c.fadeInFrames = 0
            shiftKeyframeTracks(&c, by: headCut)
        }
        if end < clip.endFrame { c.fadeOutFrames = 0 }
        c.startFrame = start + shift
        c.durationFrames = end - start
        c.clampFadesToDuration()
        c.clampKeyframesToDuration()
        // Unique per nest instance so the same child nested twice can't collide.
        c.id = "\(nestId)/\(clip.id)"
        return c
    }

    private static func shiftKeyframeTracks(_ clip: inout Clip, by headCut: Int) {
        clip.opacityTrack = clip.opacityTrack?.rebased(by: headCut, fallback: clip.opacity)
        clip.volumeTrack = clip.volumeTrack?.rebased(by: headCut, fallback: 0)
        clip.positionTrack = clip.positionTrack?.rebased(by: headCut, fallback: AnimPair(a: 0, b: 0))
        clip.scaleTrack = clip.scaleTrack?.rebased(by: headCut, fallback: AnimPair(a: 1, b: 1))
        clip.rotationTrack = clip.rotationTrack?.rebased(by: headCut, fallback: 0)
        clip.cropTrack = clip.cropTrack?.rebased(by: headCut, fallback: clip.crop)
    }
}
