import CoreGraphics
import Foundation

extension EditorViewModel {
    /// Keeps the canvas partially visible: pan cannot exceed half the scaled overflow.
    func clampCanvasOffset() {
        guard canvasViewportSize.width > 0, canvasViewportSize.height > 0 else { return }
        var zoom = PreviewZoom()
        zoom.scale = Double(canvasZoom)
        zoom.panX = Double(canvasOffset.width)
        zoom.panY = Double(canvasOffset.height)
        zoom.clampPan(viewport: canvasViewportSize)
        let clamped = CGSize(width: zoom.panX, height: zoom.panY)
        guard clamped != canvasOffset else { return }
        canvasOffset = clamped
    }
}
