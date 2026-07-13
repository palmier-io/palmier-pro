import CoreGraphics
import Foundation

/// Maps a point in the preview (top-left origin, view space) to the topmost visible
/// clip drawn under it at the current playhead frame, for click-to-select.
@MainActor
enum PreviewHitTester {
    static func clipID(at point: CGPoint, viewSize: CGSize, editor: EditorViewModel) -> String? {
        let videoRect = videoContentRect(in: viewSize, timeline: editor.timeline)
        guard videoRect.width > 0, videoRect.height > 0 else { return nil }
        let frame = editor.playheadState.timelineFrame

        // Text draws above all video; within text, higher track index is on top, so keep the last hit.
        var topText: String?
        for track in editor.timeline.tracks where !track.hidden {
            for clip in track.clips where clip.mediaType == .text {
                guard clip.contains(timelineFrame: frame), clip.opacityAt(frame: frame) > 0.01 else { continue }
                if textHit(clip, point: point, videoRect: videoRect) { topText = clip.id }
            }
        }
        if let topText { return topText }

        // Video/image: track 0 is topmost (see CompositionBuilder), so first hit wins.
        for track in editor.timeline.tracks where track.type != .audio && !track.hidden {
            for clip in track.clips where clip.mediaType != .text && clip.mediaType != .audio {
                guard clip.contains(timelineFrame: frame), clip.opacityAt(frame: frame) > 0.01 else { continue }
                if videoHit(clip, frame: frame, point: point, videoRect: videoRect) { return clip.id }
            }
        }
        return nil
    }

    /// Text renders as an axis-aligned `CATextLayer` from the static transform — no rotation/crop.
    private static func textHit(_ clip: Clip, point: CGPoint, videoRect: CGRect) -> Bool {
        clipFrame(clip.transform, videoRect: videoRect).contains(point)
    }

    private static func videoHit(_ clip: Clip, frame: Int, point: CGPoint, videoRect: CGRect) -> Bool {
        let t = clip.transformAt(frame: frame)
        let rect = clipFrame(t, videoRect: videoRect)
        guard rect.width > 0, rect.height > 0 else { return false }

        // Move the point into the clip's unrotated local space (origin at clip center).
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let rad = t.rotation * .pi / 180
        let c = cos(rad), s = sin(rad)
        let dx = point.x - center.x, dy = point.y - center.y
        let lx = dx * c + dy * s
        let ly = -dx * s + dy * c

        // Local rect spans ±half-extents; crop trims it (crop is source-space, so local too).
        let crop = clip.cropAt(frame: frame)
        let halfW = rect.width / 2, halfH = rect.height / 2
        let left = -halfW + crop.left * rect.width
        let right = halfW - crop.right * rect.width
        let top = -halfH + crop.top * rect.height
        let bottom = halfH - crop.bottom * rect.height
        return lx >= left && lx <= right && ly >= top && ly <= bottom
    }

    static func videoContentRect(in viewSize: CGSize, timeline: Timeline) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0 else { return .zero }
        let videoAspect = CGFloat(timeline.width) / CGFloat(timeline.height)
        let viewAspect = viewSize.width / viewSize.height
        let w: CGFloat, h: CGFloat
        if viewAspect > videoAspect {
            h = viewSize.height; w = h * videoAspect
        } else {
            w = viewSize.width; h = w / videoAspect
        }
        return CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2, width: w, height: h)
    }

    private static func clipFrame(_ t: Transform, videoRect: CGRect) -> CGRect {
        let tl = t.topLeft
        return CGRect(
            x: videoRect.origin.x + tl.x * videoRect.width,
            y: videoRect.origin.y + tl.y * videoRect.height,
            width: t.width * videoRect.width,
            height: t.height * videoRect.height
        )
    }
}
