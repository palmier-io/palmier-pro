import AppKit
import SwiftUI

struct MaskPointSelectionOverlayView: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(AppTheme.Background.clearColor)
                .contentShape(Rectangle())
                .onHover { hovering in
                    (hovering ? NSCursor.crosshair : NSCursor.arrow).set()
                }
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        select(at: value.location, viewSize: geometry.size)
                    }
                )
        }
        .onDisappear { NSCursor.arrow.set() }
    }

    private func select(at point: CGPoint, viewSize: CGSize) {
        let videoRect = PreviewHitTester.videoContentRect(in: viewSize, timeline: editor.timeline)
        guard let clipId = editor.maskPointSelectionClipId,
              let clip = editor.clipFor(id: clipId),
              videoRect.contains(point),
              let sourcePoint = PreviewHitTester.sourceNormalizedPoint(
                  at: point,
                  viewSize: viewSize,
                  clip: clip,
                  frame: editor.activeFrame,
                  timeline: editor.timeline
              )
        else {
            NSSound.beep()
            return
        }
        let canvasPoint = CGPoint(
            x: (point.x - videoRect.minX) / videoRect.width,
            y: (point.y - videoRect.minY) / videoRect.height
        )
        do {
            try editor.commitMaskPointSelection(
                clipId: clipId,
                sourcePoint: sourcePoint,
                canvasPoint: canvasPoint
            )
        } catch {
            Log.masking.warning("mask point selection failed: \(Log.detail(error))")
            NSSound.beep()
        }
    }
}

struct MaskPointMarkerView: View {
    let marker: MaskPointMarker

    var body: some View {
        GeometryReader { geometry in
            Circle()
                .fill(AppTheme.Status.errorColor)
                .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
                .overlay {
                    Circle().stroke(
                        AppTheme.Text.primaryColor,
                        lineWidth: AppTheme.BorderWidth.thin
                    )
                }
                .position(
                    x: marker.canvasPoint.x * geometry.size.width,
                    y: marker.canvasPoint.y * geometry.size.height
                )
        }
        .allowsHitTesting(false)
    }
}
