import SwiftUI

struct GeneratingOverlay: View {
    @State private var shimmerOffset: CGFloat = -1
    @State private var progress: CGFloat = 0

    private static let shimmerWidth: CGFloat = 0.1
    private static let shimmerDuration: Double = 1.5
    private static let progressDuration: Double = 45
    private static let progressTarget: CGFloat = 0.9

    var body: some View {
        VStack(spacing: AppTheme.Spacing.sm) {
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
        Text("Generating...")
            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            .foregroundStyle(.white.opacity(0.5))
            .overlay {
                Text("Generating...")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
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
                    .fill(Color.white.opacity(0.15))
                Capsule()
                    .fill(Color.white.opacity(0.6))
                    .frame(width: geo.size.width * progress)
            }
        }
        .frame(width: 60, height: 3)
    }
}
