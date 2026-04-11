import SwiftUI

struct PreviewContainerView: View {
    @Environment(EditorViewModel.self) var editor
    @Namespace private var tabNamespace

    private var isTimeline: Bool { editor.activePreviewTab == .timeline }
    private var isImage: Bool { editor.activePreviewTab.clipType == .image }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            ZStack {
                PreviewView()
                if isImage {
                    imagePreview
                }
            }
            if !isImage {
                scrubBar
                transportBar
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
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
        .frame(height: 28)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.Border.primaryColor).frame(height: 0.5)
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
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm - 1)
                        .fill(Color.white.opacity(0.08))
                        .matchedGeometryEffect(id: "activePreviewTab", in: tabNamespace)
                }
            }
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

    private var scrubBar: some View {
        GeometryReader { geo in
            let progress = durationFrames > 0 ? CGFloat(playheadFrame) / CGFloat(durationFrames) : 0
            let thumbSize: CGFloat = isScrubbing ? 12 : 8
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: max(0, geo.size.width * progress))
                Circle()
                    .fill(Color.white)
                    .frame(width: thumbSize, height: thumbSize)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                    .position(x: geo.size.width * progress, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
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
        .frame(height: 6)
        .animation(.easeOut(duration: 0.15), value: isScrubbing)
    }

    // MARK: - Transport bar

    private var playheadFrame: Int {
        isTimeline ? editor.currentFrame : editor.sourcePlayheadFrame
    }

    private var durationFrames: Int {
        editor.activePreviewDurationFrames
    }

    private var transportBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(formatTimecode(frame: playheadFrame, fps: editor.timeline.fps))
                .monospacedDigit()
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Spacer()

            HStack(spacing: AppTheme.Spacing.xs) {
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

            Spacer()

            Text(formatTimecode(frame: durationFrames, fps: editor.timeline.fps))
                .monospacedDigit()
                .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(height: 32)
        .overlay(alignment: .top) {
            Rectangle().fill(AppTheme.Border.primaryColor).frame(height: 0.5)
        }
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
                .font(.system(size: AppTheme.FontSize.md))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(ToolbarHoverButtonStyle())
    }
}
