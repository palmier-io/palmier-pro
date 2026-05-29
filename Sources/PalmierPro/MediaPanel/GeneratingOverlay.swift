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

    @State private var shimmerOffset: CGFloat = -1
    @State private var progress: CGFloat = 0

    private static let shimmerWidth: CGFloat = 0.1
    private static let shimmerDuration: Double = 1.5
    private static let progressDuration: Double = 45
    private static let progressTarget: CGFloat = 0.9

    var body: some View {
        VStack(spacing: size.spacing) {
            shimmerText
            progressBar
        }
        .onAppear {
            withAnimation(.linear(duration: Self.shimmerDuration).repeatForever(autoreverses: false)) {
                shimmerOffset = 1 + Self.shimmerWidth
            }
            withAnimation(.easeOut(duration: Self.progressDuration)) {
                progress = Self.progressTarget
            }
        }
    }

    private var shimmerText: some View {
        Text(label)
            .font(.system(size: size.fontSize, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .overlay {
                Text(label)
                    .font(.system(size: size.fontSize, weight: .medium))
                    .foregroundStyle(.white)
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: shimmerOffset - Self.shimmerWidth),
                                .init(color: .white, location: shimmerOffset),
                                .init(color: .clear, location: shimmerOffset + Self.shimmerWidth),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
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
