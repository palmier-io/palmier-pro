import SwiftUI

struct GeneratingOverlay: View {
    enum Size {
        case thumbnail
        case preview

        var fontSize: CGFloat { self == .preview ? AppTheme.FontSize.xl : AppTheme.FontSize.xs }
        var spacing: CGFloat { self == .preview ? AppTheme.Spacing.md : AppTheme.Spacing.sm }
        var barWidth: CGFloat { self == .preview ? 160 : 60 }
        var barHeight: CGFloat { self == .preview ? 4 : 3 }
    }

    var label: String = "Generating…"
    var size: Size = .thumbnail

    @State private var progress: CGFloat = 0

    private static let progressDuration: Double = 45
    private static let progressTarget: CGFloat = 0.9

    var body: some View {
        VStack(spacing: size.spacing) {
            Text(label)
                .font(.system(size: size.fontSize, weight: .semibold))
                .foregroundStyle(AppTheme.aiGradient)
            progressBar
        }
        .onAppear {
            withAnimation(.easeOut(duration: Self.progressDuration)) {
                progress = Self.progressTarget
            }
        }
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(AppTheme.Opacity.muted))
                Capsule()
                    .fill(Color.white.opacity(AppTheme.Opacity.strong))
                    .frame(width: geo.size.width * progress)
            }
        }
        .frame(width: size.barWidth, height: size.barHeight)
    }
}
