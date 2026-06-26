import SwiftUI

/// Shown once after sign-in during the beta. Sets expectations for testers and
/// emphasizes that feedback drives the product.
struct BetaWelcomeOverlay: View {
    let onDismiss: () -> Void

    private struct Point: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
    }

    private let points: [Point] = [
        Point(icon: "testtube.2",
              text: "Kawenreel is in early beta — some features may change or occasionally misbehave."),
        Point(icon: "key.horizontal",
              text: "Add your own AI key (Anthropic or OpenRouter) in Settings to use the agent."),
        Point(icon: "tray.and.arrow.down",
              text: "Keep your source footage and save often — projects may need re-importing as we update."),
        Point(icon: "questionmark.circle",
              text: "Stuck? Tap the “?” in the editor for how-to guides."),
        Point(icon: "exclamationmark.bubble",
              text: "Hit a bug or have an idea? Use the feedback button in the editor — anytime."),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(AppTheme.Opacity.strong).ignoresSafeArea()
            card.frame(width: 520)
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            header
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                ForEach(points) { point in
                    HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
                        Image(systemName: point.icon)
                            .font(.system(size: AppTheme.FontSize.md))
                            .foregroundStyle(AppTheme.Accent.primary)
                            .frame(width: AppTheme.IconSize.md)
                        Text(point.text)
                            .font(.system(size: AppTheme.FontSize.smMd))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            feedbackCallout
            HStack {
                Spacer()
                Button("Start editing") { onDismiss() }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, AppTheme.Spacing.xs)
        }
        .padding(AppTheme.Spacing.xxl)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text("Welcome to Kawenreel")
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                BetaBadge()
            }
            Text("Your AI video editor.")
                .font(.system(size: AppTheme.FontSize.smMd))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }

    private var feedbackCallout: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.smMd) {
            Image(systemName: "heart.fill")
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Accent.primary)
                .frame(width: AppTheme.IconSize.md)
            Text("We read every piece of feedback — it directly shapes what we build next. Thank you for helping us improve Kawenreel.")
                .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous)
                .fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint))
        )
    }
}
