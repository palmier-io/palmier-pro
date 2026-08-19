import SwiftUI

struct AudioPanelTab: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var musicExpanded = true
    @State private var silenceExpanded = false
    @State private var speakerExpanded = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                    MusicSection(isExpanded: $musicExpanded)
                    SpeechAnalysisSections(
                        silenceExpanded: $silenceExpanded,
                        speakerExpanded: $speakerExpanded
                    )
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            if let phase = editor.speakerIdentifyPhase {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                GeneratingOverlay(label: phase, size: .preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
    }
}
