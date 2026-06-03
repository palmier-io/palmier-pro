import SwiftUI

struct GeneratingOverlay: View {
    enum Size {
        case thumbnail
        case preview

        var fontSize: CGFloat { self == .preview ? AppTheme.FontSize.xl : AppTheme.FontSize.xs }
        var spacing: CGFloat { self == .preview ? AppTheme.Spacing.lg : AppTheme.Spacing.smMd }
        var barWidth: CGFloat { self == .preview ? 160 : 60 }
        var barHeight: CGFloat { self == .preview ? 4 : 3 }
    }

    var label: String = "Generating…"
    var size: Size = .thumbnail

    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let progressDuration: Double = 45
    private static let progressTarget: CGFloat = 0.9

    var body: some View {
        content
            .shimmering(active: !reduceMotion)
            .onAppear {
                if reduceMotion {
                    progress = Self.progressTarget
                } else {
                    withAnimation(.easeOut(duration: Self.progressDuration)) {
                        progress = Self.progressTarget
                    }
                }
            }
    }

    private var content: some View {
        VStack(spacing: size.spacing) {
            Text(label)
                .font(.system(size: size.fontSize, weight: .semibold))
                .foregroundStyle(AppTheme.aiGradient)
            progressBar
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

private struct ShimmerModifier: ViewModifier {
    let active: Bool

    @State private var phase: CGFloat = -1

    private static let duration: Double = 1.35

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    GeometryReader { geo in
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .white.opacity(0.42), location: 0.48),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: geo.size.width * 0.45)
                        .rotationEffect(.degrees(18))
                        .offset(x: geo.size.width * phase)
                    }
                    .blendMode(.screen)
                    .mask(content)
                }
            }
            .onAppear {
                guard active else { return }
                phase = -1
                withAnimation(.linear(duration: Self.duration).repeatForever(autoreverses: false)) {
                    phase = 2
                }
            }
    }
}

private extension View {
    func shimmering(active: Bool) -> some View {
        modifier(ShimmerModifier(active: active))
    }
}
