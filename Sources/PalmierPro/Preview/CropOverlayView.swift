import SwiftUI

struct CropOverlayView: View {
    @Environment(EditorViewModel.self) var editor

    private let handleSize: CGFloat = 8
    private let borderColor = AppTheme.Accent.timecodeColor
    private let dimColor = Color.black.opacity(0.55)
    private let guideColor = AppTheme.Accent.timecodeColor.opacity(0.35)

    var body: some View {
        GeometryReader { geo in
            let videoRect = videoContentRect(in: geo.size)

            if let clip = selectedClip {
                let clipRect = clipFrame(clip.transform, videoRect: videoRect)
                let cropRect = cropFrame(clip.crop, in: clipRect)

                Canvas { ctx, _ in
                    let dim = GraphicsContext.Shading.color(dimColor)
                    ctx.fill(Path(CGRect(x: clipRect.minX, y: clipRect.minY, width: clipRect.width, height: cropRect.minY - clipRect.minY)), with: dim)
                    ctx.fill(Path(CGRect(x: clipRect.minX, y: cropRect.maxY, width: clipRect.width, height: clipRect.maxY - cropRect.maxY)), with: dim)
                    ctx.fill(Path(CGRect(x: clipRect.minX, y: cropRect.minY, width: cropRect.minX - clipRect.minX, height: cropRect.height)), with: dim)
                    ctx.fill(Path(CGRect(x: cropRect.maxX, y: cropRect.minY, width: clipRect.maxX - cropRect.maxX, height: cropRect.height)), with: dim)

                    var thirds = Path()
                    for i in 1...2 {
                        let f = CGFloat(i) / 3
                        thirds.move(to: CGPoint(x: cropRect.minX + cropRect.width * f, y: cropRect.minY))
                        thirds.addLine(to: CGPoint(x: cropRect.minX + cropRect.width * f, y: cropRect.maxY))
                        thirds.move(to: CGPoint(x: cropRect.minX, y: cropRect.minY + cropRect.height * f))
                        thirds.addLine(to: CGPoint(x: cropRect.maxX, y: cropRect.minY + cropRect.height * f))
                    }
                    ctx.stroke(thirds, with: .color(guideColor), lineWidth: 1)
                    ctx.stroke(Path(cropRect), with: .color(borderColor), lineWidth: 1.5)
                }
                .allowsHitTesting(false)

                ForEach(Corner.allCases, id: \.self) { corner in
                    let pos = cornerPosition(corner, in: cropRect)
                    Rectangle()
                        .fill(borderColor)
                        .frame(width: handleSize, height: handleSize)
                        .position(x: pos.x, y: pos.y)
                        .gesture(resizeGesture(clip: clip, corner: corner, clipRect: clipRect))
                }
            }
        }
        .allowsHitTesting(selectedClip != nil)
    }

    // MARK: - Drag

    @State private var dragStart: Crop?

    private func resizeGesture(clip: Clip, corner: Corner, clipRect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if dragStart == nil { dragStart = clip.crop }
                guard let start = dragStart else { return }
                let updated = resizedCrop(start, corner: corner, by: value.translation, clipRect: clipRect, clip: clip)
                editor.applyClipProperty(clipId: clip.id) { $0.crop = updated }
            }
            .onEnded { value in
                guard let start = dragStart else { return }
                let updated = resizedCrop(start, corner: corner, by: value.translation, clipRect: clipRect, clip: clip)
                dragStart = nil
                editor.commitClipProperty(clipId: clip.id) { $0.crop = updated }
            }
    }

    private func resizedCrop(_ start: Crop, corner: Corner, by translation: CGSize, clipRect: CGRect, clip: Clip) -> Crop {
        guard clipRect.width > 0, clipRect.height > 0 else { return start }
        let minVis = 0.05
        if let aspectN = lockedAspectNormalized(for: clip) {
            return resizedCropLocked(start, corner: corner, translation: translation, clipRect: clipRect, aspectN: aspectN, minVis: minVis)
        }

        let dx = Double(translation.width / clipRect.width)
        let dy = Double(translation.height / clipRect.height)
        var L = start.left, T = start.top, R = start.right, B = start.bottom
        switch corner {
        case .topLeft:     L += dx; T += dy
        case .topRight:    R -= dx; T += dy
        case .bottomLeft:  L += dx; B -= dy
        case .bottomRight: R -= dx; B -= dy
        }
        L = max(0, min(L, 1 - minVis - R))
        R = max(0, min(R, 1 - minVis - L))
        T = max(0, min(T, 1 - minVis - B))
        B = max(0, min(B, 1 - minVis - T))
        return Crop(left: L, top: T, right: R, bottom: B)
    }

    /// Aspect-locked corner drag.
    private func resizedCropLocked(_ start: Crop, corner: Corner, translation: CGSize, clipRect: CGRect, aspectN: Double, minVis: Double) -> Crop {
        let dx = Double(translation.width / clipRect.width)
        let dy = Double(translation.height / clipRect.height)
        let L = start.left, T = start.top, R = start.right, B = start.bottom
        let startVisW = 1 - L - R
        let startVisH = 1 - T - B

        // widthDelta/heightDelta are signed changes to the visible region's size; the
        // sign per corner follows from which edge the handle moves.
        let widthDelta: Double
        let heightDelta: Double
        switch corner {
        case .topLeft:     widthDelta = -dx; heightDelta = -dy
        case .topRight:    widthDelta =  dx; heightDelta = -dy
        case .bottomLeft:  widthDelta = -dx; heightDelta =  dy
        case .bottomRight: widthDelta =  dx; heightDelta =  dy
        }

        // Drive from whichever axis the user moved further (in width-equivalent units).
        let sFromW = startVisW + widthDelta
        let sFromH = aspectN * (startVisH + heightDelta)
        var s = abs(widthDelta) > abs(heightDelta * aspectN) ? sFromW : sFromH

        // Bounds for s (visible width) such that the visible rect still fits in the
        // source AND visH = s/aspectN also fits.
        let sMaxFromX = (corner == .topRight || corner == .bottomRight) ? (1 - L) : (1 - R)
        let sMaxFromY = (corner == .bottomLeft || corner == .bottomRight) ? aspectN * (1 - T) : aspectN * (1 - B)
        let sMax = min(sMaxFromX, sMaxFromY)
        let sMin = max(minVis, minVis * aspectN)
        guard sMax >= sMin else { return start }
        s = min(max(s, sMin), sMax)

        let newVisW = s
        let newVisH = s / aspectN
        var newL = L, newT = T, newR = R, newB = B
        switch corner {
        case .topLeft:
            newL = 1 - R - newVisW
            newT = 1 - B - newVisH
        case .topRight:
            newR = 1 - L - newVisW
            newT = 1 - B - newVisH
        case .bottomLeft:
            newL = 1 - R - newVisW
            newB = 1 - T - newVisH
        case .bottomRight:
            newR = 1 - L - newVisW
            newB = 1 - T - newVisH
        }
        return Crop(left: newL, top: newT, right: newR, bottom: newB)
    }

    private func lockedAspectNormalized(for clip: Clip) -> Double? {
        guard let target = editor.cropAspectLock.pixelAspect,
              let srcAspect = sourcePixelAspect(for: clip), srcAspect > 0 else { return nil }
        return target / srcAspect
    }

    private func sourcePixelAspect(for clip: Clip) -> Double? {
        guard let asset = editor.mediaAssets.first(where: { $0.id == clip.mediaRef }),
              let sw = asset.sourceWidth, let sh = asset.sourceHeight,
              sw > 0, sh > 0 else { return nil }
        return Double(sw) / Double(sh)
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

    private func cropFrame(_ c: Crop, in clipRect: CGRect) -> CGRect {
        CGRect(
            x: clipRect.minX + c.left * clipRect.width,
            y: clipRect.minY + c.top * clipRect.height,
            width: c.visibleWidthFraction * clipRect.width,
            height: c.visibleHeightFraction * clipRect.height
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
              !editor.selectedClipIds.isEmpty else { return nil }
        var match: Clip?
        for track in editor.timeline.tracks where track.type != .audio {
            for clip in track.clips where editor.selectedClipIds.contains(clip.id) && clip.mediaType != .text {
                if match != nil { return nil }
                match = clip
            }
        }
        return match
    }

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }
}
