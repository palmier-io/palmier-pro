import SwiftUI

struct TransformOverlayView: View {
    @Environment(EditorViewModel.self) var editor

    private let handleSize: CGFloat = 8
    private let borderColor = Color.white.opacity(0.5)

    var body: some View {
        GeometryReader { geo in
            let videoRect = videoContentRect(in: geo.size)

            if let clip = selectedClip {
                let clipRect = clipFrame(clip.transform, videoRect: videoRect)

                Rectangle()
                    .stroke(borderColor, lineWidth: 1)
                    .frame(width: clipRect.width, height: clipRect.height)
                    .position(x: clipRect.midX, y: clipRect.midY)

                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: clipRect.width, height: clipRect.height)
                    .position(x: clipRect.midX, y: clipRect.midY)
                    .gesture(moveGesture(clip: clip, videoRect: videoRect))

                ForEach(Corner.allCases, id: \.self) { corner in
                    let pos = cornerPosition(corner, in: clipRect)
                    Rectangle()
                        .fill(borderColor)
                        .frame(width: handleSize, height: handleSize)
                        .position(x: pos.x, y: pos.y)
                        .gesture(resizeGesture(clip: clip, corner: corner, videoRect: videoRect))
                }
            }

            if centerGuideX {
                Rectangle()
                    .fill(centerGuideColor)
                    .frame(width: 1, height: videoRect.height)
                    .position(x: videoRect.midX, y: videoRect.midY)
                    .allowsHitTesting(false)
            }
            if centerGuideY {
                Rectangle()
                    .fill(centerGuideColor)
                    .frame(width: videoRect.width, height: 1)
                    .position(x: videoRect.midX, y: videoRect.midY)
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(selectedClip != nil)
    }

    // MARK: - Gestures

    @State private var dragStart: Transform?
    @State private var resizeStart: Transform?
    @State private var centerGuideX: Bool = false
    @State private var centerGuideY: Bool = false

    private let centerGuideColor = Color(red: 1.0, green: 0.2, blue: 0.6).opacity(0.9)

    private func moveGesture(clip: Clip, videoRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = clip.transform }
                guard let start = dragStart else { return }
                let (moved, snap) = movedTransform(start, by: value.translation, in: videoRect)
                if centerGuideX != snap.x { centerGuideX = snap.x }
                if centerGuideY != snap.y { centerGuideY = snap.y }
                editor.applyClipProperty(clipId: clip.id) { $0.transform = moved }
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                let (moved, _) = movedTransform(start, by: value.translation, in: videoRect)
                dragStart = nil
                if centerGuideX { centerGuideX = false }
                if centerGuideY { centerGuideY = false }
                editor.commitClipProperty(clipId: clip.id) { $0.transform = moved }
            }
    }

    private func movedTransform(_ start: Transform, by translation: CGSize, in videoRect: CGRect) -> (Transform, (x: Bool, y: Bool)) {
        guard videoRect.width > 0, videoRect.height > 0 else {
            Log.preview.warning("movedTransform: collapsed videoRect \(videoRect.debugDescription) — skipping")
            return (start, (false, false))
        }
        var t = start
        t.x += translation.width / videoRect.width
        t.y += translation.height / videoRect.height
        t.snapToCanvasEdges(threshold: Snap.thresholdPixels / Double(videoRect.width))
        let snap = t.snapCenterToCanvasCenter(
            thresholdH: Snap.thresholdPixels / Double(videoRect.width),
            thresholdV: Snap.thresholdPixels / Double(videoRect.height)
        )
        return (t, snap)
    }

    private func resizeGesture(clip: Clip, corner: Corner, videoRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStart == nil { resizeStart = clip.transform }
                guard let start = resizeStart else { return }
                let resized = resizedTransform(start, corner: corner, by: value.translation, in: videoRect, mediaCanvasAspect: mediaCanvasAspect)
                editor.applyClipProperty(clipId: clip.id) { $0.transform = resized }
            }
            .onEnded { value in
                guard let start = resizeStart else { return }
                let resized = resizedTransform(start, corner: corner, by: value.translation, in: videoRect, mediaCanvasAspect: mediaCanvasAspect)
                resizeStart = nil
                editor.commitClipProperty(clipId: clip.id) { $0.transform = resized }
            }
    }

    private func resizedTransform(_ start: Transform, corner: Corner, by translation: CGSize, in videoRect: CGRect, mediaCanvasAspect: Double?) -> Transform {
        guard videoRect.width > 0, videoRect.height > 0 else {
            Log.preview.warning("resizedTransform: collapsed videoRect \(videoRect.debugDescription) — skipping")
            return start
        }
        let dx = translation.width / videoRect.width
        let dy = translation.height / videoRect.height
        let tl = start.topLeft
        var left = tl.x, top = tl.y
        var right = left + start.width, bottom = top + start.height

        switch corner {
        case .topLeft:     left += dx; top += dy
        case .topRight:    right += dx; top += dy
        case .bottomLeft:  left += dx; bottom += dy
        case .bottomRight: right += dx; bottom += dy
        }

        // Constrain to media aspect ratio if available
        if let aspect = mediaCanvasAspect {
            let w = right - left
            let h = bottom - top
            let widthFromHeight = h * aspect

            if abs(w) >= abs(widthFromHeight) {
                let adjustedH = w / aspect
                switch corner {
                case .topLeft, .topRight: top = bottom - adjustedH
                case .bottomLeft, .bottomRight: bottom = top + adjustedH
                }
            } else {
                let adjustedW = h * aspect
                switch corner {
                case .topLeft, .bottomLeft: left = right - adjustedW
                case .topRight, .bottomRight: right = left + adjustedW
                }
            }
        }

        // Snap dragged edges to canvas boundaries, then re-apply aspect ratio
        let snapH = Snap.thresholdPixels / Double(videoRect.width)
        let snapV = Snap.thresholdPixels / Double(videoRect.height)
        let movesLeft = corner == .topLeft || corner == .bottomLeft
        let movesTop = corner == .topLeft || corner == .topRight

        let snappedH = Transform.snapToBoundary(movesLeft ? left : right, threshold: snapH)
        let snappedV = Transform.snapToBoundary(movesTop ? top : bottom, threshold: snapV)

        if snappedH != (movesLeft ? left : right) {
            if movesLeft { left = snappedH } else { right = snappedH }
            if let aspect = mediaCanvasAspect {
                if movesTop { top = bottom - (right - left) / aspect } else { bottom = top + (right - left) / aspect }
            }
        } else if snappedV != (movesTop ? top : bottom) {
            if movesTop { top = snappedV } else { bottom = snappedV }
            if let aspect = mediaCanvasAspect {
                if movesLeft { left = right - (bottom - top) * aspect } else { right = left + (bottom - top) * aspect }
            }
        }

        return Transform(
            topLeft: (left, top),
            width: max(0.05, right - left),
            height: max(0.05, bottom - top)
        )
    }

    // MARK: - Layout

    private func videoContentRect(in viewSize: CGSize) -> CGRect {
        let videoAspect = CGFloat(editor.timeline.width) / CGFloat(editor.timeline.height)
        let viewAspect = viewSize.width / viewSize.height
        let w: CGFloat, h: CGFloat
        if viewAspect > videoAspect {
            h = viewSize.height; w = h * videoAspect
        } else {
            w = viewSize.width; h = w / videoAspect
        }
        return CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2, width: w, height: h)
    }

    private func clipFrame(_ t: Transform, videoRect: CGRect) -> CGRect {
        let tl = t.topLeft
        return CGRect(
            x: videoRect.origin.x + tl.x * videoRect.width,
            y: videoRect.origin.y + tl.y * videoRect.height,
            width: t.width * videoRect.width,
            height: t.height * videoRect.height
        )
    }

    private func cornerPosition(_ corner: Corner, in rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft:     CGPoint(x: rect.minX, y: rect.minY)
        case .topRight:    CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft:  CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    private var mediaCanvasAspect: Double? {
        guard let clip = selectedClip else { return nil }
        return editor.mediaCanvasAspect(for: clip)
    }

    // MARK: - Selection

    private var selectedClip: Clip? {
        guard editor.activePreviewTab == .timeline,
              !editor.selectedClipIds.isEmpty else { return nil }
        for track in editor.timeline.tracks where track.type != .audio {
            for clip in track.clips where editor.selectedClipIds.contains(clip.id) {
                return clip
            }
        }
        return nil
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }
}
