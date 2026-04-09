import SwiftUI
import AVFoundation

struct PreviewView: NSViewRepresentable {
    @Environment(EditorViewModel.self) var editor

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        let engine = VideoEngine(editor: editor)
        view.playerLayer.player = engine.player
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

/// NSView that hosts an AVPlayerLayer for video preview.
final class PreviewNSView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }
}
