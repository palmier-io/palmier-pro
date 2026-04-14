import SwiftUI

struct PreviewContainerView: View {
    @Environment(EditorViewModel.self) var editor
    @Namespace private var tabNamespace

    private var isTimeline: Bool { editor.activePreviewTab == .timeline }
    private var isImage: Bool { editor.activePreviewTab.clipType == .image }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar reserves its own space
            GlassEffectContainer {
                tabBar
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.top, AppTheme.Spacing.xs)
            .padding(.bottom, AppTheme.Spacing.xs)

            GeometryReader { geo in
                let aspect = CGFloat(editor.timeline.width) / CGFloat(editor.timeline.height)
                let fitSize = fitSize(in: geo.size, aspect: aspect)
                ZStack {
                    PreviewView()
                    if isImage {
                        imagePreview
                    }
                    TransformOverlayView()
                }
                .frame(width: fitSize.width, height: fitSize.height)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            if !isImage {
                scrubBar
                transportBar
            }
        }
        .background(AppTheme.Background.canvasColor)
    }

    // MARK: - Transport bar

    private var transportBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(formatTimecode(frame: playheadFrame, fps: editor.timeline.fps))
                .monospacedDigit()
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Accent.timecodeColor)

            Spacer()

            HStack(spacing: AppTheme.Spacing.md) {
                transportButton("backward.end.fill") { seekTo(0) }
                transportButton("backward.frame.fill") { seekTo(playheadFrame - 1) }
                transportButton(editor.isPlaying ? "pause.fill" : "play.fill") {
                    if isTimeline {
                        editor.togglePlayback()
                    } else {
                        editor.toggleSourcePlayback()
                    }
                }
                transportButton("forward.frame.fill") { seekTo(playheadFrame + 1) }
                transportButton("forward.end.fill") { seekTo(durationFrames) }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
            .glassEffect(.regular, in: .capsule)

            Spacer()

            Text(formatTimecode(frame: durationFrames, fps: editor.timeline.fps))
                .monospacedDigit()
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(height: 36)
    }

    // MARK: - Image preview

    private var imagePreview: some View {
        Group {
            if let asset = activeMediaAsset, let image = asset.thumbnail ?? NSImage(contentsOf: asset.url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    private func fitSize(in container: CGSize, aspect: CGFloat) -> CGSize {
        let widthFromHeight = container.height * aspect
        if widthFromHeight <= container.width {
            return CGSize(width: widthFromHeight, height: container.height)
        }
        return CGSize(width: container.width, height: container.width / aspect)
    }

    private var activeMediaAsset: MediaAsset? {
        guard case .mediaAsset(let id, _, _) = editor.activePreviewTab else { return nil }
        return editor.mediaAssets.first { $0.id == id }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(editor.previewTabs) { tab in
                tabButton(for: tab)
            }
            Spacer()
        }
    }

    private func tabButton(for tab: PreviewTab) -> some View {
        let isActive = editor.activePreviewTabId == tab.id

        return Button {
            withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                editor.selectPreviewTab(id: tab.id)
            }
        } label: {
            HStack(spacing: 4) {
                Text(tab.displayName)
                    .font(.system(size: AppTheme.FontSize.xs, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)

                if tab.isCloseable {
                    closeButton(tabId: tab.id)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.xs)
            .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
            .glassEffect(isActive ? .regular.tint(tab.tintColor) : .identity, in: .capsule)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func closeButton(tabId: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                editor.closePreviewTab(id: tabId)
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Scrub bar

    @State private var isScrubbing = false
    @State private var isScrubHovered = false

    private var scrubBar: some View {
        GeometryReader { geo in
            let progress = durationFrames > 0 ? CGFloat(playheadFrame) / CGFloat(durationFrames) : 0
            let active = isScrubbing || isScrubHovered
            let thumbSize: CGFloat = active ? 10 : 6
            let barHeight: CGFloat = active ? 4 : 3
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: barHeight)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width * progress), height: barHeight)
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    .position(x: geo.size.width * progress, y: geo.size.height / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                isScrubHovered = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        let fraction = max(0, min(1, value.location.x / geo.size.width))
                        let frame = Int(fraction * CGFloat(durationFrames))
                        seekTo(frame)
                    }
                    .onEnded { _ in
                        isScrubbing = false
                    }
            )
        }
        .frame(height: 12)
        .animation(.easeOut(duration: 0.15), value: isScrubbing)
        .animation(.easeOut(duration: 0.15), value: isScrubHovered)
        .onDisappear {
            if isScrubHovered {
                NSCursor.pop()
                isScrubHovered = false
            }
        }
    }

    // MARK: - Transport helpers

    private var playheadFrame: Int {
        isTimeline ? editor.currentFrame : editor.sourcePlayheadFrame
    }

    private var durationFrames: Int {
        editor.activePreviewDurationFrames
    }

    private func seekTo(_ frame: Int) {
        if isTimeline {
            editor.seekToFrame(frame)
        } else {
            editor.seekSourceToFrame(frame)
        }
    }

    private func transportButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
    }
}
