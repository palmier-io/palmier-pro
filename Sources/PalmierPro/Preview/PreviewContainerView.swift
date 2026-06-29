import AppKit
import SwiftUI

struct PreviewContainerView: View {
    @Environment(EditorViewModel.self) var editor

    private var isTimeline: Bool { editor.activePreviewTab == .timeline }
    private var isImage: Bool { editor.activePreviewTab.clipType == .image }

    @State private var hoveredTabId: String?

    var body: some View {
        VStack(spacing: 0) {
            tabBar
                .padding(.horizontal, AppTheme.Spacing.sm)
                .panelHeaderBar()

            GeometryReader { geo in
                let aspect = generatingAspect ?? CGFloat(editor.timeline.width) / CGFloat(editor.timeline.height)
                let fitSize = fitSize(in: geo.size, aspect: aspect)
                let scaledWidth = fitSize.width * editor.canvasZoom
                let scaledHeight = fitSize.height * editor.canvasZoom
                let timelineState = timelineFrameState
                ZStack {
                    PreviewView()
                    if isImage {
                        imagePreview
                    }
                    if let error = activeFailedError {
                        failedPreview(error: error)
                    }
                    if let asset = activeMediaAsset, asset.isGenerating {
                        generatingPreview(label: asset.generatingLabel)
                    } else if case .generating(let label) = timelineState {
                        generatingPreview(label: label)
                    }
                    if let overlay = offlineOverlay(timelineState: timelineState) {
                        offlinePreview(assetId: overlay.assetId, path: overlay.path, isUnprocessable: overlay.isUnprocessable)
                    }
                    if editor.cropEditingActive {
                        CropOverlayView()
                    } else {
                        TransformOverlayView()
                    }
                }
                .frame(width: scaledWidth, height: scaledHeight)
                .simultaneousGesture(
                    SpatialTapGesture(count: 2)
                        .onEnded { value in
                            guard isTimeline,
                                  let id = PreviewHitTester.clipID(
                                    at: value.location,
                                    viewSize: CGSize(width: scaledWidth, height: scaledHeight),
                                    editor: editor
                                  ) else { return }
                            editor.selectedClipIds = editor.expandToLinkGroup([id])
                        }
                )
                .overlay(
                    Rectangle()
                        .stroke(Color.white.opacity(editor.canvasZoom < 1.0 ? AppTheme.Opacity.moderate : 0), lineWidth: AppTheme.BorderWidth.thin)
                )
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                .offset(x: editor.canvasOffset.width, y: editor.canvasOffset.height)
            }
            .clipped()
            if !isImage {
                scrubBar
                transportBar
            } else {
                imageSettingsBar
            }
        }
        .background(AppTheme.Background.surfaceColor)
    }

    // MARK: - Transport bar

    private var transportBar: some View {
        let duration = durationFrames
        let fps = editor.timeline.fps
        let durationTimecode = formatTimecode(frame: duration, fps: fps)

        return HStack(spacing: AppTheme.Spacing.sm) {
            PreviewTimecodeText(
                isTimeline: isTimeline,
                fps: fps,
                durationTimecode: durationTimecode
            )

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
                transportButton("forward.end.fill") { seekTo(duration) }
            }

            Spacer()

            if isTimeline || editor.activePreviewTab.clipType == .video {
                captureFrameButton
            }
            settingsMenuButton(label: zoomBadgeLabel, help: "Canvas Zoom") { zoomMenuItems }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(height: 36)
    }

    // MARK: - Image settings bar

    private var imageSettingsBar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Spacer()
            settingsMenuButton(label: zoomBadgeLabel, help: "Canvas Zoom") { zoomMenuItems }
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .frame(height: 36)
    }

    // MARK: - Capture frame

    private var captureFrameButton: some View {
        Button(action: editor.captureCurrentFrameToMedia) {
            Image(systemName: "camera")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .hoverHighlight()
                .help("Capture Frame to Media")
        }
        .buttonStyle(.plain)
        .tourAnchor(.screenshotButton)
    }

    // MARK: - Project settings

    @ViewBuilder
    private var zoomMenuItems: some View {
        ForEach(ZoomPreset.allCases, id: \.self) { preset in
            Button {
                editor.canvasOffset = .zero
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

    private func settingsMenuButton<MenuContent: View>(
        label: String,
        help: String,
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
        .hoverHighlight()
        .help(help)
    }

    private func badgeLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.xxs, weight: .bold, design: .rounded))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(height: AppTheme.IconSize.mdLg)
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
        .allowsHitTesting(false)
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

    private var generatingAspect: CGFloat? {
        guard let asset = activeMediaAsset, asset.isGenerating else { return nil }
        let parts = (asset.generationInput?.aspectRatio ?? "").split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return CGFloat(parts[0] / parts[1])
    }

    private var activeFailedError: String? {
        guard let asset = activeMediaAsset,
              case .failed(let error) = asset.generationStatus else { return nil }
        return error
    }

    private var activeMediaMissing: Bool {
        guard let asset = activeMediaAsset, case .none = asset.generationStatus else { return false }
        return editor.isMediaOffline(asset.id)
    }

    private enum TimelineFrameState {
        case covered
        case generating(String)
        case offline(Clip)
        case none
    }

    private var timelineFrameState: TimelineFrameState {
        guard isTimeline else { return .none }
        let hasOffline = !editor.offlineMediaRefs.isEmpty
            || !editor.unprocessableMediaRefs.isEmpty
            || !editor.missingMediaRefs.isEmpty
        let hasGenerating = editor.mediaAssets.contains(where: \.isGenerating)
        guard hasOffline || hasGenerating else { return .none }
        let frame = editor.playheadState.timelineFrame
        var offline: Clip?
        var generatingLabel: String?
        for track in editor.timeline.tracks where track.type != .audio && !track.hidden {
            for clip in track.clips where clip.mediaType != .text {
                guard clip.contains(timelineFrame: frame), clip.opacityAt(frame: frame) > 0.01 else { continue }
                if let asset = generatingAsset(for: clip) {
                    generatingLabel = generatingLabel ?? asset.generatingLabel
                } else if editor.isMediaOffline(clip.mediaRef) {
                    offline = offline ?? clip
                } else {
                    return .covered
                }
            }
        }
        if let generatingLabel { return .generating(generatingLabel) }
        if let offline { return .offline(offline) }
        return .none
    }

    private func generatingAsset(for clip: Clip) -> MediaAsset? {
        editor.mediaAssets.first { $0.id == clip.mediaRef && $0.isGenerating }
    }

    private struct OfflineOverlay { let assetId: String?; let path: String?; let isUnprocessable: Bool }

    private func offlineOverlay(timelineState: TimelineFrameState) -> OfflineOverlay? {
        if activeMediaMissing, let id = activeMediaAsset?.id {
            return OfflineOverlay(assetId: id, path: activeMediaAsset?.url.path, isUnprocessable: editor.isMediaUnprocessable(id))
        }
        if case .offline(let clip) = timelineState {
            return OfflineOverlay(
                assetId: clip.mediaRef,
                path: editor.mediaResolver.expectedURL(for: clip.mediaRef)?.path,
                isUnprocessable: editor.isMediaUnprocessable(clip.mediaRef)
            )
        }
        return nil
    }

    private func relinkFile(assetId: String) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the source file for this clip"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            editor.relinkAsset(id: assetId, to: url)
        }
    }

    private func relinkFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder that holds your media"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let result = editor.relinkOfflineAssets(fromFolder: url)
            editor.mediaPanelToast = "Relinked \(result.relinked) of \(result.total) offline clips."
        }
    }

    private func generatingPreview(label: String) -> some View {
        ZStack {
            if let image = activeGeneratingReferenceImage {
                Color.clear
                    .overlay { Image(nsImage: image).resizable().scaledToFill().blur(radius: 24) }
                    .clipped()
            }
            Color.black.opacity(AppTheme.Opacity.strong)
            GeneratingOverlay(label: label, size: .preview)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .allowsHitTesting(false)
    }

    private var activeGeneratingReferenceImage: NSImage? {
        guard let input = activeMediaAsset?.generationInput else { return nil }
        let refIds = (input.imageURLAssetIds ?? []) + (input.referenceImageAssetIds ?? [])
        for id in refIds {
            guard let ref = editor.mediaAssets.first(where: { $0.id == id }), ref.type == .image else { continue }
            if let image = ref.thumbnail ?? NSImage(contentsOf: ref.url) {
                return image
            }
        }
        return nil
    }

    private static func unprocessablePrefill(path: String?) -> String {
        let file = path.map { ($0 as NSString).lastPathComponent } ?? "(unknown)"
        return """
        A clip's media couldn't be prepared for playback.

        File: \(file)

        What were you doing when this happened?
        """
    }

    private func offlinePreview(assetId: String?, path: String?, isUnprocessable: Bool) -> some View {
        ZStack {
            Color.black.opacity(AppTheme.Opacity.strong)
            VStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.display))
                    .foregroundStyle(AppTheme.Status.errorColor)
                Text(isUnprocessable ? "Couldn't Prepare Media" : "Media Offline")
                    .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(isUnprocessable
                    ? "Palmier loaded this clip's source file but couldn't prepare it for playback. The file may be corrupt or in an unsupported format."
                    : "Palmier couldn't load this clip's source file. It may be missing, on an ejected drive, or unreadable.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppTheme.Spacing.lg)
                if let path {
                    Text(path)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .padding(.horizontal, AppTheme.Spacing.lg)
                }
                if isUnprocessable {
                    Button("Report a Problem") {
                        FeedbackWindowController.shared.show(prefill: Self.unprocessablePrefill(path: path))
                    }
                    .buttonStyle(.capsule(.prominent, size: .regular))
                    .padding(.top, AppTheme.Spacing.xs)
                } else {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        if let assetId {
                            Button("Relink…") { relinkFile(assetId: assetId) }
                                .buttonStyle(.capsule(.prominent, size: .regular))
                        }
                        Button("Relink Folder…") { relinkFolder() }
                            .buttonStyle(.capsule(.secondary, size: .regular))
                    }
                    .padding(.top, AppTheme.Spacing.xs)
                }
            }
            .padding(AppTheme.Spacing.xl)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func failedPreview(error: String) -> some View {
        ZStack {
            Color.black.opacity(AppTheme.Opacity.strong)
            VStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: AppTheme.FontSize.display))
                    .foregroundStyle(.red.opacity(AppTheme.Opacity.prominent))
                Text("Generation Failed")
                    .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                ScrollView {
                    Text(error)
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, AppTheme.Spacing.lg)
                }
                .frame(maxWidth: 520, maxHeight: 240)
                .fixedSize(horizontal: false, vertical: true)
                if let asset = activeMediaAsset, asset.pendingDownloadURL != nil {
                    Button {
                        editor.generationService.retryDownload(asset: asset, editor: editor)
                    } label: {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: "arrow.clockwise")
                            Text("Retry Download")
                        }
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .padding(.horizontal, AppTheme.Spacing.md)
                        .padding(.vertical, AppTheme.Spacing.sm)
                    }
                    .buttonStyle(.plain)
                    .background(.white.opacity(AppTheme.Opacity.soft), in: .capsule)
                    .overlay(Capsule().strokeBorder(.white.opacity(AppTheme.Opacity.muted), lineWidth: AppTheme.BorderWidth.hairline))
                }
            }
            .padding(AppTheme.Spacing.xl)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            HStack(spacing: 0) {
                navButton("chevron.left", enabled: editor.canGoBackPreviewTab, help: "Back") {
                    editor.goBackPreviewTab()
                }
                navButton("chevron.right", enabled: editor.canGoForwardPreviewTab, help: "Forward") {
                    editor.goForwardPreviewTab()
                }
            }

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        ForEach(editor.previewTabs) { tab in
                            tabItem(for: tab).id(tab.id)
                        }
                    }
                    .padding(.horizontal, AppTheme.Spacing.sm)
                }
                .mouseWheelScrollsHorizontally()
                .onChange(of: editor.activePreviewTabId) { _, newId in
                    withAnimation(.easeOut(duration: AppTheme.Anim.transition)) {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
            }

            overflowMenu
        }
    }

    private func tabItem(for tab: PreviewTab) -> some View {
        let isActive = tab.id == editor.activePreviewTabId
        let isHovered = hoveredTabId == tab.id
        return HStack(spacing: AppTheme.Spacing.xs) {
            Text(tab.displayName)
                .font(.system(size: AppTheme.FontSize.xs, weight: isActive ? .semibold : .medium))
                .foregroundStyle(isActive || isHovered ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                .lineLimit(1)

            if tab.isCloseable {
                closeButton(tabId: tab.id)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xs)
        .padding(.bottom, AppTheme.Spacing.xs)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? tab.underlineColor : Color.clear)
                .frame(height: AppTheme.BorderWidth.medium)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture {
            editor.selectPreviewTab(id: tab.id)
        }
        .onHover { hovering in
            if hovering {
                hoveredTabId = tab.id
            } else if hoveredTabId == tab.id {
                hoveredTabId = nil
            }
        }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isActive)
    }

    private func navButton(_ systemName: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(enabled ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.md)
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }

    private var overflowMenu: some View {
        Menu {
            Button("Close All Tabs") {
                withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                    editor.closeAllPreviewTabs()
                }
            }
            .disabled(editor.previewTabs.count <= 1)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        .help("More")
    }

    private func closeButton(tabId: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                editor.closePreviewTab(id: tabId)
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: AppTheme.FontSize.micro, weight: .bold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                .hoverHighlight(cornerRadius: 7)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Scrub bar

    @State private var isScrubbing = false
    @State private var isScrubHovered = false
    @State private var scrubWasPlaying = false

    private var scrubBar: some View {
        let duration = durationFrames

        return GeometryReader { geo in
            let active = isScrubbing || isScrubHovered
            let thumbSize: CGFloat = active ? 10 : 6
            let barHeight: CGFloat = active ? 4 : 3
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(AppTheme.Opacity.soft))
                    .frame(height: barHeight)
                PreviewScrubProgress(
                    isTimeline: isTimeline,
                    durationFrames: duration,
                    geometry: .init(
                        size: geo.size,
                        barHeight: barHeight,
                        thumbSize: thumbSize
                    )
                )
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
                        beginScrubIfNeeded()
                        seekTo(
                            scrubFrame(
                                locationX: value.location.x,
                                width: geo.size.width,
                                durationFrames: duration
                            ),
                            mode: .interactiveScrub
                        )
                    }
                    .onEnded { value in
                        finishScrub(
                            at: scrubFrame(
                                locationX: value.location.x,
                                width: geo.size.width,
                                durationFrames: duration
                            )
                        )
                    }
            )
        }
        .frame(height: 12)
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isScrubbing)
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isScrubHovered)
        .onDisappear {
            if isScrubHovered {
                NSCursor.pop()
                isScrubHovered = false
            }
            if isScrubbing {
                finishScrub(at: playheadFrame)
            }
        }
    }

    // MARK: - Transport helpers

    private var playheadFrame: Int {
        isTimeline ? editor.playheadState.timelineFrame : editor.playheadState.sourceFrame
    }

    private var durationFrames: Int {
        editor.activePreviewDurationFrames
    }

    private func beginScrubIfNeeded() {
        guard !isScrubbing else { return }
        scrubWasPlaying = editor.isPlaying
        if scrubWasPlaying { editor.pause() }
        editor.isScrubbing = true
        isScrubbing = true
    }

    private func finishScrub(at frame: Int) {
        let shouldResume = scrubWasPlaying
        scrubWasPlaying = false
        isScrubbing = false
        editor.isScrubbing = false
        seekTo(frame, mode: .exact)
        if shouldResume { editor.resumePlayback() }
    }

    private func scrubFrame(locationX: CGFloat, width: CGFloat, durationFrames: Int) -> Int {
        guard width > 0 else { return 0 }
        let fraction = max(0, min(1, locationX / width))
        return Int(fraction * CGFloat(max(0, durationFrames)))
    }

    private func seekTo(_ frame: Int, mode: PreviewSeekMode = .exact) {
        if isTimeline {
            editor.seekToFrame(frame, mode: mode)
        } else {
            editor.seekSourceToFrame(frame, mode: mode)
        }
    }

    private func transportButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 32, height: 28)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings Presets

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

// MARK: - Hot-path subviews

private struct PreviewTimecodeText: View {
    @Environment(EditorViewModel.self) var editor
    let isTimeline: Bool
    let fps: Int
    let durationTimecode: String

    var body: some View {
        let frame = isTimeline ? editor.playheadState.timelineFrame : editor.playheadState.sourceFrame
        HStack(spacing: 0) {
            Text(formatTimecode(frame: frame, fps: fps))
                .foregroundStyle(AppTheme.Accent.timecodeColor)
            Text(" / ")
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Text(durationTimecode)
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .monospacedDigit()
        .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
    }
}

private struct PreviewScrubProgress: View {
    struct Geometry {
        let size: CGSize
        let barHeight: CGFloat
        let thumbSize: CGFloat
    }

    @Environment(EditorViewModel.self) var editor
    let isTimeline: Bool
    let durationFrames: Int
    let geometry: Geometry

    var body: some View {
        let frame = isTimeline ? editor.playheadState.timelineFrame : editor.playheadState.sourceFrame
        let duration = durationFrames
        let progress = duration > 0 ? CGFloat(frame) / CGFloat(duration) : 0
        let g = geometry
        ZStack(alignment: .leading) {
            Capsule()
                .fill(AppTheme.Accent.primary)
                .frame(width: max(0, g.size.width * progress), height: g.barHeight)
            Circle()
                .fill(Color.white)
                .frame(width: g.thumbSize, height: g.thumbSize)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                .position(x: g.size.width * progress, y: g.size.height / 2)
        }
    }
}
