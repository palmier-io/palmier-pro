import AVKit
import SwiftUI

struct StoryboardPreviewView: View {
    let controller: StoryboardPreviewController
    let prepare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Button(L10n.string("Preview Storyboard"), action: prepare)
                    .disabled(controller.isPreparing)
                if controller.isPreparing {
                    ProgressView().controlSize(.small)
                    Button(L10n.string("Cancel")) { controller.invalidate() }
                } else if controller.result != nil {
                    Text(controller.measured ? L10n.string("Measured narration") : L10n.string("Estimated timing · silent preview"))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
            }
            if let player = controller.player {
                StoryboardPreviewPlayer(player: player)
                    .frame(height: AppTheme.Storyboard.previewHeight)
            }
            if let error = controller.error {
                Text(verbatim: error).font(.system(size: AppTheme.FontSize.xs)).foregroundStyle(AppTheme.Status.errorColor)
            }
            Text(L10n.string("Preview does not approve production or certify source inspection."))
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }
}

private struct StoryboardPreviewPlayer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) { view.player = nil }
}
