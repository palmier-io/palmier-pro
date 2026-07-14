import SwiftUI

struct SampleProjectsStrip: View {
    @State private var samples: [SampleProjectService.Summary] = []
    @State private var activeDownload: SampleDownload?
    @AppStorage("samplesSectionExpanded") private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !samples.isEmpty {
                strip
            }
        }
        .task { samples = (try? await SampleProjectService.shared.fetchSamples()) ?? [] }
    }

    private var strip: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Button {
                withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text("Sample Project")
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Image(systemName: "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        ForEach(samples) { sample in
                            SampleCard(
                                sample: sample,
                                download: activeDownload?.slug == sample.slug ? activeDownload : nil
                            ) { start(sample) }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.bottom, AppTheme.Spacing.xxl)
    }

    private func start(_ sample: SampleProjectService.Summary) {
        if SampleProjectService.shared.cachedURL(slug: sample.slug) != nil {
            Task { try? await AppState.shared.openSample(slug: sample.slug, startTutorial: true) }
            return
        }
        activeDownload = SampleDownload(slug: sample.slug)
        Task {
            do {
                try await AppState.shared.openSample(slug: sample.slug, startTutorial: true) { progress in
                    activeDownload?.progress = progress
                }
                activeDownload = nil
            } catch {
                activeDownload?.failed = true
            }
        }
    }
}

struct SampleDownload {
    let slug: String
    var progress: Double = 0
    var failed = false
}

private struct SampleCard: View {
    let sample: SampleProjectService.Summary
    let download: SampleDownload?
    let action: () -> Void

    @State private var isHovered = false

    private let cardRadius: CGFloat = AppTheme.Radius.mdLg
    private let downloadBlur: CGFloat = 4

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            poster
                .frame(width: AppTheme.ComponentSize.projectCardWidth, height: AppTheme.ComponentSize.projectCardHeight)
                .blur(radius: download == nil ? 0 : downloadBlur)
                .clipped()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.7), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 60)
            .allowsHitTesting(false)

            Text(sample.title)
                .font(.system(size: AppTheme.FontSize.smMd, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.bottom, AppTheme.Spacing.smMd)

            if let download {
                downloadOverlay(download)
            }
        }
        .frame(width: AppTheme.ComponentSize.projectCardWidth, height: AppTheme.ComponentSize.projectCardHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            if download == nil || download?.failed == true { action() }
        }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(isHovered ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        )
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
        .help(sample.title)
        .padding(AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private func downloadOverlay(_ download: SampleDownload) -> some View {
        ZStack {
            Color.black.opacity(AppTheme.Opacity.faint)
            if download.failed {
                VStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                    Text("Retry")
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                }
                .foregroundStyle(AppTheme.Text.primaryColor)
            } else {
                ProgressView(value: download.progress)
                    .progressViewStyle(.linear)
                    .tint(AppTheme.Accent.primary)
                    .padding(.horizontal, AppTheme.Spacing.lg)
            }
        }
        .frame(width: AppTheme.ComponentSize.projectCardWidth, height: AppTheme.ComponentSize.projectCardHeight)
    }

    @ViewBuilder
    private var poster: some View {
        if let urlString = sample.posterUrl, let url = URL(string: urlString) {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                AppTheme.Background.placeholderColor
            }
        } else {
            AppTheme.Background.placeholderColor
                .overlay {
                    Image(systemName: "film")
                        .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
        }
    }
}
