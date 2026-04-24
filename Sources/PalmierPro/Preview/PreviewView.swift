import SwiftUI
import AVFoundation

struct PreviewView: NSViewRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        let engine = VideoEngine(editor: editor)
        view.playerLayer.player = engine.player
        engine.previewView = view
        view.setTextRoot(engine.textController.textRoot)
        view.onVideoRectChange = { [weak engine] _ in engine?.syncTextLayers() }
        context.coordinator.engine = engine
        editor.videoEngine = engine
        engine.activateTab(editor.activePreviewTab)
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        // Sync playback state
        guard let engine = context.coordinator.engine else { return }
        if editor.isPlaying && engine.player.timeControlStatus != .playing {
            engine.play()
        } else if !editor.isPlaying && engine.player.timeControlStatus == .playing {
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

    private var lastVideoRect: CGRect = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
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
        playerLayer.frame = bounds
        let videoRect = resolvedVideoRect
        textRoot?.frame = videoRect
        if videoRect != lastVideoRect {
            lastVideoRect = videoRect
            onVideoRectChange?(videoRect)
        }
    }

    private var resolvedVideoRect: CGRect {
        let rect = playerLayer.videoRect
        return rect.isEmpty ? bounds : rect
    }
}
