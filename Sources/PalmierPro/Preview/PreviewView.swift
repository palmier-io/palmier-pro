import SwiftUI
import AVFoundation
import CoreImage

struct PreviewView: NSViewRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        let engine = VideoEngine(editor: editor)
        view.playerLayer.player = engine.player
        engine.previewView = view
        view.setTextRoot(engine.textController.textRoot)
        view.onVideoRectChange = { [weak engine] _ in engine?.syncTextLayers() }
        view.onCmdScroll = { [weak editor] deltaY, pointTopDown, viewSize in
            guard let editor = editor else { return }
            let oldZoom = editor.canvasZoom
            let factor = exp(deltaY)
            let newZoom = min(max(oldZoom * factor, 0.1), 8.0)
            if abs(newZoom - oldZoom) < 0.0001 { return }

            // F (fit-canvas size) = view bounds / current zoom
            let fitW = viewSize.width / oldZoom
            let fitH = viewSize.height / oldZoom

            let dx = fitW * (newZoom - oldZoom) / 2 + pointTopDown.x * (1 - newZoom / oldZoom)
            let dy = fitH * (newZoom - oldZoom) / 2 + pointTopDown.y * (1 - newZoom / oldZoom)

            let newOffset = CGSize(
                width: editor.canvasOffset.width + dx,
                height: editor.canvasOffset.height + dy
            )
            editor.canvasOffset = newOffset
            editor.canvasZoom = newZoom
        }
        context.coordinator.engine = engine
        editor.videoEngine = engine
        engine.activateTab(editor.activePreviewTab)
        view.applyGrade(primaries: editor.timeline.primaries, lut: editor.timeline.lut)
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        guard let engine = context.coordinator.engine else { return }
        nsView.applyGrade(primaries: editor.timeline.primaries, lut: editor.timeline.lut)
        if editor.isPlaying && engine.player.timeControlStatus == .paused {
            engine.play()
        } else if !editor.isPlaying && engine.player.timeControlStatus != .paused {
            engine.pause()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var engine: VideoEngine?
    }

    static func dismantleNSView(_ nsView: PreviewNSView, coordinator: Coordinator) {
        coordinator.engine?.teardown()
    }
}

/// Hosts AVPlayerLayer + a direct CALayer tree for text overlays.
final class PreviewNSView: NSView {
    let playerLayer = AVPlayerLayer()
    private(set) var textRoot: CALayer?

    /// Fires when `playerLayer.videoRect` changes so text layers can re-scale.
    var onVideoRectChange: ((CGRect) -> Void)?

    /// Fires on cmd+scroll. (deltaY, pointInTopDownViewCoords, viewSize)
    var onCmdScroll: ((CGFloat, CGPoint, CGSize) -> Void)?

    private var lastVideoRect: CGRect = .zero
    private var appliedPrimaries: PrimaryGrade?
    private var appliedLUT: LUTRef?

    /// Live color grade via macOS `CALayer.filters` on the video layer (text stays ungraded).
    func applyGrade(primaries: PrimaryGrade?, lut: LUTRef?) {
        guard primaries != appliedPrimaries || lut != appliedLUT else { return }
        appliedPrimaries = primaries
        appliedLUT = lut
        let filters = GradePipeline.filters(primaries: primaries, lut: lut)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.filters = filters.isEmpty ? nil : filters
        CATransaction.commit()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = AppTheme.Background.surface.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Attach the text layer tree above `playerLayer` — persists across item swaps.
    func setTextRoot(_ new: CALayer?) {
        textRoot?.removeFromSuperlayer()
        textRoot = new
        if let new, let host = layer {
            host.addSublayer(new)
            new.frame = resolvedVideoRect
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        let videoRect = resolvedVideoRect
        textRoot?.frame = videoRect
        CATransaction.commit()
        if videoRect != lastVideoRect {
            lastVideoRect = videoRect
            onVideoRectChange?(videoRect)
        }
    }

    private var resolvedVideoRect: CGRect {
        let rect = playerLayer.videoRect
        return rect.isEmpty ? bounds : rect
    }

    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command), let onCmdScroll else {
            super.scrollWheel(with: event)
            return
        }
        let locInView = convert(event.locationInWindow, from: nil)
        let topDown = CGPoint(x: locInView.x, y: bounds.height - locInView.y)
        let sensitivity: CGFloat = event.hasPreciseScrollingDeltas ? 0.005 : 0.05
        let delta = event.scrollingDeltaY * sensitivity
        if delta == 0 { return }
        onCmdScroll(delta, topDown, bounds.size)
    }
}
