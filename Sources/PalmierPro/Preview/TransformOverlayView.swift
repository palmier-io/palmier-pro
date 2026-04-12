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
        }
        .allowsHitTesting(selectedClip != nil)
    }

    // MARK: - Gestures

    @State private var dragStart: Transform?
    @State private var resizeStart: Transform?

    private func moveGesture(clip: Clip, videoRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = clip.transform }
                guard let start = dragStart else { return }
                let moved = movedTransform(start, by: value.translation, in: videoRect)
                editor.applyClipProperty(clipId: clip.id) { $0.transform = moved }
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                let moved = movedTransform(start, by: value.translation, in: videoRect)
                dragStart = nil
                editor.commitClipProperty(clipId: clip.id) { $0.transform = moved }
            }
    }

    private func movedTransform(_ start: Transform, by translation: CGSize, in videoRect: CGRect) -> Transform {
        var t = start
        t.x += translation.width / videoRect.width
        t.y += translation.height / videoRect.height
        t.clampToBounds()
        return t
    }

    private func resizeGesture(clip: Clip, corner: Corner, videoRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if resizeStart == nil { resizeStart = clip.transform }
                guard let start = resizeStart else { return }
                let resized = resizedTransform(start, corner: corner, by: value.translation, in: videoRect)
                editor.applyClipProperty(clipId: clip.id) { $0.transform = resized }
            }
            .onEnded { value in
                guard let start = resizeStart else { return }
                let resized = resizedTransform(start, corner: corner, by: value.translation, in: videoRect)
                resizeStart = nil
                editor.commitClipProperty(clipId: clip.id) { $0.transform = resized }
            }
    }

    private func resizedTransform(_ start: Transform, corner: Corner, by translation: CGSize, in videoRect: CGRect) -> Transform {
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

        left = max(0, left); top = max(0, top)
        right = min(1, right); bottom = min(1, bottom)

        return Transform(
            topLeft: (max(0, left), max(0, top)),
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

    // MARK: - Selection

    private var selectedClip: Clip? {
        guard editor.activePreviewTab == .timeline,
              editor.selectedClipIds.count == 1,
              let id = editor.selectedClipIds.first else { return nil }
        for track in editor.timeline.tracks where track.type != .audio {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }
}
