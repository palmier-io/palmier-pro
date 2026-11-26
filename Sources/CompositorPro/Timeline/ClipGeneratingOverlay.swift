import SwiftUI

struct ClipGeneratingOverlay: View {
    var body: some View {
        ZStack {
            AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.Opacity.strong)
            GeneratingOverlay()
        }
        .clipShape(RoundedRectangle(cornerRadius: Trim.clipCornerRadius))
        .allowsHitTesting(false)
    }
}
