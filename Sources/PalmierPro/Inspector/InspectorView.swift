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
            let isSingleText = selectedVisualClips.count + selectedAudioClips.count == 1
                && selectedVisualClip?.mediaType == .text
            if isSingleText {
                preferredTab = .text
            } else if preferredTab == .text {
                preferredTab = .video
            }
            editor.cropEditingActive = false
        }
        .onChange(of: preferredTab) { _, newTab in
            if newTab != .video { editor.cropEditingActive = false }
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
        let visuals = selectedVisualClips
        let audios = selectedAudioClips
        let nonText = nonTextVisualClips
        let isSingle = visuals.count + audios.count == 1
        let isSingleText = isSingle && visuals.first?.mediaType == .text

        var tabs: [ClipTab] = []
        if isSingleText { tabs.append(.text) }
        if !nonText.isEmpty { tabs.append(.video) }
        if !audios.isEmpty { tabs.append(.audio) }
        if isSingle, resolvedClipAsset != nil { tabs.append(.ai) }
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

    private var nonTextVisualClips: [Clip] {
        selectedVisualClips.filter { $0.mediaType != .text }
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
                                videoTabContent()
                            case .audio:
                                audioTabContent()
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
    private func videoTabContent() -> some View {
        let clips = nonTextVisualClips
        frameSection(clips: clips)

        if !clips.isEmpty {
            cropSection(clip: clips.count == 1 ? clips.first : nil)
        }

        InspectorSlider(
            icon: "arrow.up.left.and.arrow.down.right",
            label: "Scale",
            value: sharedClipValue(clips) { $0.transform.width },
            range: 0.01...5.0,
            displayMultiplier: 100,
            valueSuffix: "%",
            format: "%.0f",
            onChanged: { newVal in
                for c in clips {
                    let t = scaledTransform(for: c, newScale: newVal)
                    editor.applyClipProperty(clipId: c.id) { $0.transform = t }
                }
            }
        ) { newVal in
            commitToClips(clips, actionName: "Change Scale") { c in
                let t = scaledTransform(for: c, newScale: newVal)
                editor.commitClipProperty(clipId: c.id) { $0.transform = t }
            }
        }

        InspectorSlider(
            icon: "circle.lefthalf.filled",
            label: "Opacity",
            value: sharedClipValue(clips) { $0.opacity },
            range: 0...1,
            displayMultiplier: 100,
            valueSuffix: "%",
            format: "%.0f",
            onChanged: { newVal in
                for c in clips { editor.applyClipProperty(clipId: c.id) { $0.opacity = newVal } }
            }
        ) { newVal in
            commitToClips(clips, actionName: "Change Opacity") { c in
                editor.commitClipProperty(clipId: c.id) { $0.opacity = newVal }
            }
        }

        speedSlider(clips: clips + selectedAudioClips)
    }

    @ViewBuilder
    private func audioTabContent() -> some View {
        let audios = selectedAudioClips
        InspectorSlider(
            icon: "speaker.wave.2.fill",
            label: "Volume",
            value: sharedClipValue(audios) { VolumeScale.dbFromLinear($0.volume) },
            range: VolumeScale.floorDb...VolumeScale.ceilingDb,
            displayMultiplier: 1,
            valueSuffix: " dB",
            format: "%.1f",
            displayTextOverride: { db in
                db <= VolumeScale.floorDb ? "-∞ dB" : nil
            },
            onChanged: { db in
                let lin = VolumeScale.linearFromDb(db)
                for c in audios { editor.applyClipProperty(clipId: c.id) { $0.volume = lin } }
            }
        ) { db in
            let lin = VolumeScale.linearFromDb(db)
            commitToClips(audios, actionName: "Change Volume") { c in
                editor.commitClipProperty(clipId: c.id) { $0.volume = lin }
            }
        }

        if nonTextVisualClips.isEmpty {
            speedSlider(clips: audios)
        }
    }

    private func speedSlider(clips: [Clip]) -> some View {
        InspectorSlider(
            icon: "gauge.with.dots.needle.67percent",
            label: "Speed",
            value: sharedClipValue(clips) { $0.speed },
            range: 0.25...4.0,
            displayMultiplier: 1,
            valueSuffix: "x",
            format: "%.2f",
            onChanged: { newVal in
                for c in clips { editor.applyClipSpeed(clipId: c.id, newSpeed: newVal) }
            }
        ) { newVal in
            editor.commitClipSpeed(ids: clips.map(\.id), newSpeed: newVal)
        }
    }

    private func commitToClips(_ clips: [Clip], actionName: String, _ commit: (Clip) -> Void) {
        editor.undoManager?.beginUndoGrouping()
        for c in clips { commit(c) }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName(actionName)
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
    private func frameSection(clips: [Clip]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text("Transform")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
                Button {
                    commitToClips(clips, actionName: "Reset Transform") { c in
                        editor.commitClipProperty(clipId: c.id) { $0.transform = Transform() }
                    }
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
                InspectorPositionFields(clips: clips)
                InspectorNumberField(label: "Scale", value: sharedClipValue(clips) { $0.transform.width * 100 }) { newScale in
                    commitToClips(clips, actionName: "Change Scale") { c in
                        let t = scaledTransform(for: c, newScale: max(newScale, 1) / 100.0)
                        editor.commitClipProperty(clipId: c.id) { $0.transform = t }
                    }
                }
            }
        }
    }

    // MARK: - Crop Section

    @ViewBuilder
    private func cropSection(clip: Clip?) -> some View {
        let editing = editor.cropEditingActive && clip != nil
        let cropped = clip.map { !$0.crop.isIdentity } ?? false
        let multi = clip == nil

        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Button {
                    editor.cropEditingActive.toggle()
                } label: {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "crop.rotate")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(editing ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                        Text("Crop")
                            .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        if !multi {
                            Image(systemName: editing ? "chevron.up" : "chevron.down")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(multi)
                .help(multi ? "Crop applies to one clip at a time" : (editing ? "Exit crop editing" : "Edit crop"))

                Spacer()

                if let clip, cropped {
                    Button {
                        editor.commitClipProperty(clipId: clip.id) { $0.crop = Crop() }
                        editor.cropAspectLock = .free
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .frame(width: 22, height: 22)
                            .hoverHighlight()
                    }
                    .buttonStyle(.plain)
                    .help("Reset crop")
                }
            }
            .opacity(multi ? 0.4 : 1)

            if editing, let clip {
                cropPresetRow(clip: clip)
            }
        }
    }

    @ViewBuilder
    private func cropPresetRow(clip: Clip) -> some View {
        let active = editor.cropAspectLock
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 56), spacing: AppTheme.Spacing.xs)],
            alignment: .leading,
            spacing: AppTheme.Spacing.xs
        ) {
            ForEach(CropAspectLock.allCases, id: \.self) { preset in
                let isActive = preset == active
                Button {
                    applyCropPreset(preset, on: clip)
                } label: {
                    Text(preset.label)
                        .font(.system(size: AppTheme.FontSize.xs, weight: isActive ? .medium : .regular))
                        .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                .fill(isActive ? Color.white.opacity(0.10) : Color.white.opacity(0.04))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func applyCropPreset(_ preset: CropAspectLock, on clip: Clip) {
        editor.cropAspectLock = preset
        switch preset {
        case .free:
            // Don't mutate crop; user keeps current shape and drags freely.
            break
        case .original:
            editor.commitClipProperty(clipId: clip.id) { $0.crop = Crop() }
        default:
            guard let target = preset.pixelAspect else { return }
            let newCrop = editor.cropFittingAspect(for: clip, targetPixelAspect: target)
            editor.commitClipProperty(clipId: clip.id) { $0.crop = newCrop }
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

    private var selectedVisualClips: [Clip] {
        guard !editor.selectedClipIds.isEmpty else { return [] }
        var out: [Clip] = []
        for track in editor.timeline.tracks {
            for clip in track.clips where editor.selectedClipIds.contains(clip.id) && clip.mediaType.isVisual {
                out.append(clip)
            }
        }
        return out
    }

    private var selectedAudioClips: [Clip] {
        guard !editor.selectedClipIds.isEmpty else { return [] }
        var out: [Clip] = []
        for track in editor.timeline.tracks {
            for clip in track.clips where editor.selectedClipIds.contains(clip.id) && clip.mediaType == .audio {
                out.append(clip)
            }
        }
        return out
    }

    private var selectedVisualClip: Clip? { selectedVisualClips.first }
    private var selectedAudioClip: Clip? { selectedAudioClips.first }

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

func sharedClipValue<T: Equatable>(_ clips: [Clip], _ extract: (Clip) -> T) -> T? {
    guard let first = clips.first else { return nil }
    let v = extract(first)
    for c in clips.dropFirst() where extract(c) != v { return nil }
    return v
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
