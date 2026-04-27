import AppKit
import SwiftUI

struct InspectorView: View {
    @Environment(EditorViewModel.self) var editor

    enum ClipTab: String, Hashable {
        case text = "Text"
        case video = "Video"
        case audio = "Audio"
        case ai = "AI Edit"
    }

    enum AssetTab: String, Hashable {
        case details = "Details"
        case ai = "AI Edit"
    }

    @State private var preferredTab: ClipTab = .video
    @State private var preferredAssetTab: AssetTab = .details

    private var headerTitle: String {
        if selectedVisualClip != nil || selectedAudioClip != nil { return "Inspector" }
        if activeTabAsset != nil || selectedMediaAsset != nil { return "Details" }
        return "Details"
    }

    private var headerIcon: String {
        if selectedVisualClip != nil || selectedAudioClip != nil { return "slider.horizontal.3" }
        return "info.circle"
    }

    /// Media asset from the active preview tab (when viewing a media asset tab)
    private var activeTabAsset: MediaAsset? {
        guard case .mediaAsset(let id, _, _) = editor.activePreviewTab else { return nil }
        return editor.mediaAssets.first { $0.id == id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Plain header
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: headerIcon)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(headerTitle)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer()
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.sm)

            // Content layer
            if selectedVisualClip != nil || selectedAudioClip != nil {
                clipInspectorContent()
            } else if let asset = selectedMediaAsset {
                mediaAssetInspectorContent(asset)
            } else if let asset = activeTabAsset {
                mediaAssetInspectorContent(asset)
            } else {
                projectMetadataContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: editor.selectedClipIds) { _, _ in
            if selectedVisualClip?.mediaType == .text {
                preferredTab = .text
            } else if preferredTab == .text {
                preferredTab = .video
            }
        }
    }

    // MARK: - Project Metadata

    private var projectMetadataContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                // Project info
                inspectorCard {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        if let url = editor.projectURL {
                            metadataRow("doc.text", label: "Name", value: url.deletingPathExtension().lastPathComponent)
                            metadataRow("folder", label: "Path", value: url.deletingLastPathComponent().path)
                        }
                    }
                }

                // Timeline settings
                inspectorCard {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        metadataRow("rectangle.split.3x3", label: "Resolution", value: "\(editor.timeline.width) × \(editor.timeline.height)")
                        metadataRow("film", label: "Frame Rate", value: "\(editor.timeline.fps) fps")
                        metadataRow("aspectratio", label: "Aspect Ratio", value: formatAspectRatio(width: editor.timeline.width, height: editor.timeline.height))
                        metadataRow("clock", label: "Duration", value: formatDuration(Double(editor.timeline.totalFrames) / Double(editor.timeline.fps)))
                    }
                }
            }
            .padding(AppTheme.Spacing.md)
        }
    }

    private func formatAspectRatio(width: Int, height: Int) -> String {
        let gcd = gcd(width, height)
        return "\(width / gcd):\(height / gcd)"
    }

    // MARK: - Clip Inspector

    private var availableTabs: [ClipTab] {
        var tabs: [ClipTab] = []
        let isText = selectedVisualClip?.mediaType == .text
        if isText { tabs.append(.text) }
        if selectedVisualClip != nil && !isText { tabs.append(.video) }
        if selectedAudioClip != nil { tabs.append(.audio) }
        if resolvedClipAsset != nil { tabs.append(.ai) }
        return tabs
    }

    /// Tab the view actually renders (preferred if valid, else first available).
    private var activeTab: ClipTab? {
        let tabs = availableTabs
        return tabs.contains(preferredTab) ? preferredTab : tabs.first
    }

    /// The visual-or-image MediaAsset backing the currently selected visual clip.
    private var resolvedClipAsset: MediaAsset? {
        guard let clip = selectedVisualClip, clip.mediaType.isVisual else { return nil }
        return editor.mediaAssets.first { $0.id == clip.mediaRef }
    }

    @ViewBuilder
    private func clipInspectorContent() -> some View {
        let tabs = availableTabs
        VStack(spacing: 0) {
            if tabs.count > 1 {
                tabBar(tabs)
            }
            Group {
                if activeTab == .ai, let asset = resolvedClipAsset {
                    AIEditTab(asset: asset, clipId: selectedVisualClip?.id)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                            switch activeTab {
                            case .text:
                                if let v = selectedVisualClip, v.mediaType == .text { TextTab(clip: v) }
                            case .video:
                                if let v = selectedVisualClip { videoTabContent(v) }
                            case .audio:
                                if let a = selectedAudioClip { audioTabContent(a) }
                            case .ai, .none:
                                EmptyView()
                            }
                        }
                        .padding(AppTheme.Spacing.lg)
                    }
                }
            }
        }
    }

    private func tabBar(_ tabs: [ClipTab]) -> some View {
        genericTabBar(titles: tabs.map(\.rawValue), selected: activeTab?.rawValue) { title in
            if let tab = tabs.first(where: { $0.rawValue == title }) { preferredTab = tab }
        }
    }

    private func assetTabBar(_ tabs: [AssetTab]) -> some View {
        genericTabBar(titles: tabs.map(\.rawValue), selected: preferredAssetTab.rawValue) { title in
            if let tab = tabs.first(where: { $0.rawValue == title }) { preferredAssetTab = tab }
        }
    }

    private func genericTabBar(titles: [String], selected: String?, onSelect: @escaping (String) -> Void) -> some View {
        HStack(spacing: 2) {
            ForEach(titles, id: \.self) { title in
                let isActive = selected == title
                let isAI = title == "AI Edit"
                Button {
                    onSelect(title)
                } label: {
                    Group {
                        if isAI {
                            Text(title)
                                .foregroundStyle(isActive ? AnyShapeStyle(AppTheme.aiGradient) : AnyShapeStyle(AppTheme.aiGradient.opacity(0.6)))
                        } else {
                            Text(title)
                                .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                        }
                    }
                    .font(.system(size: AppTheme.FontSize.sm, weight: isActive ? .medium : .regular))
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .hoverHighlight(isActive: isActive)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.top, AppTheme.Spacing.xs)
        .padding(.bottom, AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private func videoTabContent(_ vClip: Clip) -> some View {
        frameSection(vClip)

        InspectorSlider(
            icon: "arrow.up.left.and.arrow.down.right",
            label: "Scale",
            value: vClip.transform.width,
            range: 0.01...5.0,
            displayMultiplier: 100,
            valueSuffix: "%",
            format: "%.0f",
            onChanged: { newVal in
                let t = scaledTransform(for: vClip, newScale: newVal)
                editor.applyClipProperty(clipId: vClip.id) { $0.transform = t }
            }
        ) { newVal in
            let t = scaledTransform(for: vClip, newScale: newVal)
            editor.commitClipProperty(clipId: vClip.id) { $0.transform = t }
        }

        InspectorSlider(
            icon: "circle.lefthalf.filled",
            label: "Opacity",
            value: vClip.opacity,
            range: 0...1,
            displayMultiplier: 100,
            valueSuffix: "%",
            format: "%.0f",
            onChanged: { newVal in
                editor.applyClipProperty(clipId: vClip.id) { $0.opacity = newVal }
            }
        ) { newVal in
            editor.commitClipProperty(clipId: vClip.id) { $0.opacity = newVal }
        }

        if vClip.mediaType != .text {
            speedSlider(currentSpeed: vClip.speed)
        }
    }

    @ViewBuilder
    private func audioTabContent(_ aClip: Clip) -> some View {
        InspectorSlider(
            icon: "speaker.wave.2.fill",
            label: "Volume",
            value: VolumeScale.dbFromLinear(aClip.volume),
            range: VolumeScale.floorDb...VolumeScale.ceilingDb,
            displayMultiplier: 1,
            valueSuffix: " dB",
            format: "%.1f",
            displayTextOverride: { db in
                db <= VolumeScale.floorDb ? "-∞ dB" : nil
            },
            onChanged: { db in
                editor.applyClipProperty(clipId: aClip.id) { $0.volume = VolumeScale.linearFromDb(db) }
            }
        ) { db in
            editor.commitClipProperty(clipId: aClip.id) { $0.volume = VolumeScale.linearFromDb(db) }
        }

        if selectedVisualClip == nil {
            speedSlider(currentSpeed: aClip.speed)
        }
    }

    private func speedSlider(currentSpeed: Double) -> some View {
        InspectorSlider(
            icon: "gauge.with.dots.needle.67percent",
            label: "Speed",
            value: currentSpeed,
            range: 0.25...4.0,
            displayMultiplier: 1,
            valueSuffix: "x",
            format: "%.2f",
            onChanged: { newVal in
                applySpeedToSelection(newVal)
            }
        ) { newVal in
            commitSpeedToSelection(newVal)
        }
    }

    private func applySpeedToSelection(_ newVal: Double) {
        if let v = selectedVisualClip { editor.applyClipSpeed(clipId: v.id, newSpeed: newVal) }
        if let a = selectedAudioClip { editor.applyClipSpeed(clipId: a.id, newSpeed: newVal) }
    }

    private func commitSpeedToSelection(_ newVal: Double) {
        editor.undoManager?.beginUndoGrouping()
        if let v = selectedVisualClip { editor.commitClipSpeed(clipId: v.id, newSpeed: newVal) }
        if let a = selectedAudioClip { editor.commitClipSpeed(clipId: a.id, newSpeed: newVal) }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName("Change Speed")
    }

    private func inspectorCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(AppTheme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.white.opacity(0.04))
            )
    }

    // MARK: - Frame Section

    @ViewBuilder
    private func frameSection(_ clip: Clip) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Image(systemName: "crop")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text("Frame")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
                Button {
                    editor.commitClipProperty(clipId: clip.id) { $0.transform = Transform() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(width: 22, height: 22)
                        .hoverHighlight()
                }
                .buttonStyle(.plain)
                .help("Reset transform")
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                InspectorPositionFields(clip: clip)
                InspectorNumberField(label: "Scale", value: clip.transform.width * 100) { newScale in
                    let t = scaledTransform(for: clip, newScale: max(newScale, 1) / 100.0)
                    editor.commitClipProperty(clipId: clip.id) { $0.transform = t }
                }
            }
        }
    }

    // MARK: - Media Asset Inspector

    @ViewBuilder
    private func mediaAssetInspectorContent(_ asset: MediaAsset) -> some View {
        if asset.type.isVisual {
            VStack(spacing: 0) {
                assetTabBar([.details, .ai])
                if preferredAssetTab == .ai {
                    AIEditTab(asset: asset)
                } else {
                    assetDetailsContent(asset)
                }
            }
        } else {
            assetDetailsContent(asset)
        }
    }

    @ViewBuilder
    private func assetDetailsContent(_ asset: MediaAsset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if asset.generationInput == nil {
                    inspectorCard {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            Text(asset.name)
                                .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                                .lineLimit(2)

                            metadataRow("tag", label: "Type", value: asset.type.trackLabel)

                            if asset.type != .audio {
                                if let size = imageDimensions(for: asset.url) {
                                    metadataRow("rectangle.split.3x3", label: "Dimensions", value: "\(size.width) × \(size.height)")
                                }
                            }

                            if asset.duration > 0 && asset.type != .image {
                                metadataRow("clock", label: "Duration", value: formatDuration(asset.duration))
                            }

                            if let fileSize = fileSize(for: asset.url) {
                                metadataRow("internaldrive", label: "File Size", value: fileSize)
                            }
                        }
                    }
                }

                if let gen = asset.generationInput {
                    inspectorCard {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            Text("AI Generated")
                                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                                .foregroundStyle(AppTheme.aiGradient)

                            metadataRow("cpu", label: "Model", value: ModelRegistry.displayName(for: gen.model))
                            if !gen.aspectRatio.isEmpty {
                                metadataRow("aspectratio", label: "Aspect Ratio", value: gen.aspectRatio)
                            }

                            if let resolution = gen.resolution {
                                metadataRow("rectangle.split.3x3", label: "Resolution", value: resolution)
                            }

                            if gen.duration > 0 {
                                metadataRow("clock", label: "Duration", value: "\(gen.duration)s")
                            }

                            if !gen.prompt.isEmpty {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: AppTheme.Spacing.xs) {
                                        Text("Prompt")
                                            .font(.system(size: AppTheme.FontSize.xs))
                                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                                        Spacer()
                                        PromptCopyButton(text: gen.prompt)
                                    }
                                    Text(gen.prompt)
                                        .font(.system(size: AppTheme.FontSize.xs))
                                        .foregroundStyle(AppTheme.Text.secondaryColor)
                                        .textSelection(.enabled)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                }
            }
            .padding(AppTheme.Spacing.md)
        }
    }

    private func metadataRow(_ icon: String, label: String, value: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .frame(width: 14)
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Spacer()
            Text(value)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
    }


    // MARK: - Helpers

    /// The visual half of the current selection, if any. Frame / Scale /
    /// Opacity controls target this.
    private var selectedVisualClip: Clip? {
        guard !editor.selectedClipIds.isEmpty else { return nil }
        for track in editor.timeline.tracks {
            for clip in track.clips where editor.selectedClipIds.contains(clip.id) && clip.mediaType.isVisual {
                return clip
            }
        }
        return nil
    }

    /// The audio half of the current selection, if any. Volume targets this.
    private var selectedAudioClip: Clip? {
        guard !editor.selectedClipIds.isEmpty else { return nil }
        for track in editor.timeline.tracks {
            for clip in track.clips where editor.selectedClipIds.contains(clip.id) && clip.mediaType == .audio {
                return clip
            }
        }
        return nil
    }

    private var selectedMediaAsset: MediaAsset? {
        guard editor.selectedMediaAssetIds.count == 1,
              let id = editor.selectedMediaAssetIds.first else { return nil }
        return editor.mediaAssets.first { $0.id == id }
    }


    private func fileSize(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func imageDimensions(for url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    private func scaledTransform(for clip: Clip, newScale: Double) -> Transform {
        let aspect = editor.mediaCanvasAspect(for: clip) ?? 1.0
        let w = newScale
        let h = newScale / aspect
        return Transform(center: clip.transform.center, width: w, height: h)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frac = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        if mins > 0 {
            return String(format: "%d:%02d.%02d", mins, secs, frac)
        }
        return String(format: "%d.%02ds", secs, frac)
    }
}

// MARK: - Volume Scale

/// Maps a linear amplitude multiplier to dB for the volume slider.
/// Below the floor we snap to true 0 (hard mute) and render "-∞ dB".
enum VolumeScale {
    static let floorDb: Double = -60
    static let ceilingDb: Double = 15

    static func dbFromLinear(_ linear: Double) -> Double {
        guard linear > 0 else { return floorDb }
        return min(ceilingDb, max(floorDb, 20 * log10(linear)))
    }

    static func linearFromDb(_ db: Double) -> Double {
        guard db > floorDb else { return 0 }
        return pow(10, min(db, ceilingDb) / 20)
    }
}

struct PromptCopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(copied ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .help(copied ? "Copied" : "Copy prompt")
    }

    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            copied = false
        }
    }
}
