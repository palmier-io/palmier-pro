import SwiftUI

struct RadioIndicator: View {
    let selected: Bool
    var size: CGFloat = AppTheme.IconSize.sm
    var innerPadding: CGFloat = AppTheme.Spacing.xs

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(selected ? AppTheme.Accent.primary : AppTheme.Text.mutedColor, lineWidth: AppTheme.BorderWidth.thin)

            if selected {
                Circle()
                    .fill(AppTheme.Accent.primary)
                    .padding(innerPadding)
            }
        }
        .frame(width: size, height: size)
    }
}
