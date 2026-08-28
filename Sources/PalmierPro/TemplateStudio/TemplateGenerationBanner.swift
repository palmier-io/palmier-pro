import SwiftUI

/// Media-panel banner showing reel-to-template analysis progress with a cancel affordance.
struct TemplateGenerationBanner: View {
    let state: TemplateGenerationState
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(L10n.string("Creating template from \"\(state.assetName)\"…"))
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(stageLabel)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            Button(L10n.string("Cancel"), action: onCancel)
                .buttonStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(AppTheme.Background.prominentColor)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
        .padding(.horizontal, AppTheme.Spacing.lgXl)
        .padding(.bottom, AppTheme.Spacing.lgXl)
    }

    private var stageLabel: String {
        let percent = Int((state.progress.fraction * 100).rounded())
        switch state.progress.stage {
        case .scenes: return L10n.string("Detecting cuts… \(percent)%")
        case .audio: return L10n.string("Classifying audio…")
        case .beats: return L10n.string("Finding beats…")
        }
    }
}
