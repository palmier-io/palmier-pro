import SwiftUI

extension View {
    func appSheetBackground() -> some View {
        presentationBackground {
            AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                .background(.ultraThinMaterial)
        }
    }
}
