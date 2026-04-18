import SwiftUI

struct PreviewContainerView: View {
    @Environment(EditorViewModel.self) var editor

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
                let scaledWidth = fitSize.width * editor.canvasZoom
                let scaledHeight = fitSize.height * editor.canvasZoom
                ZStack {
                    PreviewView()
                    if isImage {
                        imagePreview
                    }
                    TransformOverlayView()
                }
                .frame(width: scaledWidth, height: scaledHeight)
                .overlay(
                    Rectangle()
                        .stroke(Color.white.opacity(editor.canvasZoom < 1.0 ? 0.25 : 0), lineWidth: 1)
                )
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            .clipped()
            if !isImage {
                scrubBar
                transportBar
            }
        }
        .background(AppTheme.Background.surfaceColor)
    }

    // MARK: - Transport bar

    private var transportBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            HStack(spacing: 0) {
                Text(formatTimecode(frame: playheadFrame, fps: editor.timeline.fps))
                    .foregroundStyle(AppTheme.Accent.timecodeColor)
                Text(" / ")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(formatTimecode(frame: durationFrames, fps: editor.timeline.fps))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .monospacedDigit()
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))

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

            projectSettingsGroup
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(height: 36)
    }

    // MARK: - Project settings

    private var projectSettingsGroup: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Spacing.md) {
                settingsMenuButton(label: aspectBadgeLabel) { aspectMenuItems }
                settingsMenuButton(label: "\(editor.timeline.fps)") { fpsMenuItems }
                settingsMenuButton(label: qualityBadgeLabel) { qualityMenuItems }
                settingsMenuButton(label: zoomBadgeLabel) { zoomMenuItems }
            }

            Menu {
                Menu("Aspect Ratio") { aspectMenuItems }
                Menu("Frame Rate") { fpsMenuItems }
                Menu("Quality") { qualityMenuItems }
                Menu("Zoom") { zoomMenuItems }
            } label: {
                badgeIcon("slider.horizontal.3")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    @ViewBuilder
    private var aspectMenuItems: some View {
        ForEach(AspectPreset.allCases, id: \.self) { preset in
            Button {
                editor.applyTimelineSettings(fps: editor.timeline.fps, width: preset.width, height: preset.height)
            } label: {
                HStack {
                    Text(preset.label)
                    Spacer()
                    if editor.timeline.width == preset.width && editor.timeline.height == preset.height {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var fpsMenuItems: some View {
        ForEach([24, 25, 30, 50, 60], id: \.self) { fps in
            Button {
                editor.applyTimelineSettings(fps: fps, width: editor.timeline.width, height: editor.timeline.height)
            } label: {
                HStack {
                    Text("\(fps) fps")
                    Spacer()
                    if editor.timeline.fps == fps {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var qualityMenuItems: some View {
        ForEach(QualityPreset.allCases, id: \.self) { preset in
            Button {
                let (w, h) = preset.resolution(currentWidth: editor.timeline.width, currentHeight: editor.timeline.height)
                editor.applyTimelineSettings(fps: editor.timeline.fps, width: w, height: h)
            } label: {
                HStack {
                    Text(preset.label)
                    Spacer()
                    if preset.matches(width: editor.timeline.width, height: editor.timeline.height) {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var zoomMenuItems: some View {
        ForEach(ZoomPreset.allCases, id: \.self) { preset in
            Button {
                editor.canvasZoom = preset.value
            } label: {
                HStack {
                    Text(preset.label)
                    Spacer()
                    if isZoomPresetActive(preset) {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    private var zoomBadgeLabel: String {
        if isZoomPresetActive(.fit) {
            return "Fit"
        }
        let percent = Int(editor.canvasZoom * 100)
        return "\(percent)%"
    }

    private func isZoomPresetActive(_ preset: ZoomPreset) -> Bool {
        abs(editor.canvasZoom - preset.value) < 0.01
    }

    private var aspectBadgeLabel: String {
        let w = editor.timeline.width
        let h = editor.timeline.height
        let g = gcd(w, h)
        return "\(w / g):\(h / g)"
    }

    private var qualityBadgeLabel: String {
        let h = min(editor.timeline.width, editor.timeline.height)
        if h <= 720 { return "HD" }
        if h <= 1080 { return "FHD" }
        if h <= 1440 { return "2K" }
        return "4K"
    }

    private func settingsMenuButton<MenuContent: View>(
        label: String,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) -> some View {
        Menu {
            menu()
        } label: {
            badgeLabel(label)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func badgeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .frame(height: 24)
    }

    private func badgeIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .frame(width: 24, height: 24)
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
            if let activeTab = editor.previewTabs.first(where: { $0.id == editor.activePreviewTabId }) {
                activeTabLabel(for: activeTab)
            }
            Spacer()
        }
    }

    private func activeTabLabel(for tab: PreviewTab) -> some View {
        HStack(spacing: 4) {
            Text(tab.displayName)
                .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                .lineLimit(1)

            if tab.isCloseable {
                closeButton(tabId: tab.id)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.xs)
        .foregroundStyle(AppTheme.Text.primaryColor)
        .glassEffect(.regular.tint(tab.tintColor), in: .capsule)
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
                .frame(width: 32, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings Presets

private enum AspectPreset: CaseIterable {
    case sixteenNine, nineByFourteen, nineSixteen, oneOne, fourThree, twoPointFourOne

    var label: String {
        switch self {
        case .sixteenNine: "16:9"
        case .nineByFourteen: "9:14"
        case .nineSixteen: "9:16"
        case .oneOne: "1:1"
        case .fourThree: "4:3"
        case .twoPointFourOne: "2.4:1"
        }
    }

    var width: Int {
        switch self {
        case .sixteenNine: 1920
        case .nineByFourteen: 1080
        case .nineSixteen: 1080
        case .oneOne: 1080
        case .fourThree: 1440
        case .twoPointFourOne: 2560
        }
    }

    var height: Int {
        switch self {
        case .sixteenNine: 1080
        case .nineByFourteen: 1680
        case .nineSixteen: 1920
        case .oneOne: 1080
        case .fourThree: 1080
        case .twoPointFourOne: 1080
        }
    }
}

private enum QualityPreset: CaseIterable {
    case hd720, fullHD, twoK, fourK

    var label: String {
        switch self {
        case .hd720: "720p"
        case .fullHD: "1080p"
        case .twoK: "2K"
        case .fourK: "4K"
        }
    }

    /// Scale resolution while preserving the current aspect ratio.
    func resolution(currentWidth: Int, currentHeight: Int) -> (width: Int, height: Int) {
        let target = shortEdge
        if currentWidth <= currentHeight {
            return (target, Int(Double(target) * Double(currentHeight) / Double(currentWidth)))
        }
        return (Int(Double(target) * Double(currentWidth) / Double(currentHeight)), target)
    }

    func matches(width: Int, height: Int) -> Bool {
        min(width, height) == shortEdge
    }

    private var shortEdge: Int {
        switch self {
        case .hd720: 720
        case .fullHD: 1080
        case .twoK: 1440
        case .fourK: 2160
        }
    }
}

private enum ZoomPreset: CaseIterable {
    case twentyFivePercent, fiftyPercent, seventyFivePercent, fit, oneTwentyFivePercent, oneFiftyPercent, twoHundredPercent

    var label: String {
        switch self {
        case .twentyFivePercent: "25%"
        case .fiftyPercent: "50%"
        case .seventyFivePercent: "75%"
        case .fit: "Fit"
        case .oneTwentyFivePercent: "125%"
        case .oneFiftyPercent: "150%"
        case .twoHundredPercent: "200%"
        }
    }

    var value: CGFloat {
        switch self {
        case .twentyFivePercent: 0.25
        case .fiftyPercent: 0.50
        case .seventyFivePercent: 0.75
        case .fit: 1.0
        case .oneTwentyFivePercent: 1.25
        case .oneFiftyPercent: 1.50
        case .twoHundredPercent: 2.0
        }
    }
}
