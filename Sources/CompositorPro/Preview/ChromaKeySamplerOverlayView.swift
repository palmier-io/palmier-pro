import AppKit
import SwiftUI

struct ChromaKeySamplerOverlayView: View {
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
                        sample(at: value.location, viewSize: geometry.size)
                    }
                )
        }
        .onDisappear { NSCursor.arrow.set() }
    }

    private func sample(at point: CGPoint, viewSize: CGSize) {
        let rect = PreviewHitTester.videoContentRect(in: viewSize, timeline: editor.timeline)
        guard let clipId = editor.chromaKeySamplingClipId,
              let engine = editor.videoEngine, rect.contains(point) else {
            NSSound.beep()
            return
        }
        let normalizedPoint = CGPoint(
            x: (point.x - rect.minX) / rect.width,
            y: (point.y - rect.minY) / rect.height
        )
        Task { @MainActor in
            guard let hue = await engine.sampleKeyHue(at: normalizedPoint, frame: editor.activeFrame) else {
                NSSound.beep()
                return
            }
            editor.commitChromaKeySample(hue: hue, clipId: clipId)
        }
    }
}
