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
    @State private var transformExpanded = true

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
        if aiEditEligible { tabs.append(.ai) }
        return tabs
    }

    /// True when the selection resolves to a single AI-editable visual clip.
    /// A linked video+audio pair counts as one
    private var aiEditEligible: Bool {
        let visuals = selectedVisualClips
        let audios = selectedAudioClips
        guard visuals.count == 1, resolvedClipAsset != nil else { return false }
        if audios.isEmpty { return true }
        let partners = Set(editor.linkedPartnerIds(of: visuals[0].id))
        return audios.allSatisfy { partners.contains($0.id) }
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
        HStack(spacing: AppTheme.Spacing.md) {
            ForEach(titles, id: \.self) { title in
                let isActive = selected == title
                let isAI = title == "AI Edit"
                let foreground: AnyShapeStyle = isAI
                    ? AnyShapeStyle(AppTheme.aiGradient.opacity(isActive ? 1 : 0.6))
                    : AnyShapeStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                Button {
                    onSelect(title)
                } label: {
                    VStack(spacing: AppTheme.Spacing.xs) {
                        Text(title)
                            .font(.system(size: AppTheme.FontSize.sm, weight: isActive ? .medium : .regular))
                            .foregroundStyle(foreground)
                        Rectangle()
                            .fill(isActive ? foreground : AnyShapeStyle(Color.clear))
                            .frame(height: 1.5)
                    }
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.lg)
        .padding(.top, AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private func videoTabContent() -> some View {
        let clips = nonTextVisualClips
        let single = clips.count == 1 ? clips.first : nil
        let kfVisible = single != nil && editor.keyframesPanelVisible

        if let clip = single, kfVisible {
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    transformSection(clips: clips)
                    if !clips.isEmpty { cropSection(clip: single) }
                    speedSection(clips: clips + selectedAudioClips)
                        .padding(.trailing, KeyframesMetrics.stampButtonWidth + AppTheme.Spacing.sm)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, AppTheme.Spacing.sm)
                Divider()
                KeyframesPanel(clip: clip)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, AppTheme.Spacing.sm)
            }
        } else {
            transformSection(clips: clips)
            if !clips.isEmpty {
                cropSection(clip: single)
            }
            speedSection(clips: clips + selectedAudioClips)
        }

        keyframesToggleBar(enabled: single != nil)
    }

    private func keyframesToggleBar(enabled: Bool) -> some View {
        let on = editor.keyframesPanelVisible
        return HStack {
            Spacer()
            Button {
                editor.keyframesPanelVisible.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: on ? "diamond.fill" : "diamond")
                        .font(.system(size: 10, weight: .medium))
                    Text("Keyframes")
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                }
                .foregroundStyle(on ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            .help(enabled ? (on ? "Hide keyframe timeline" : "Show keyframe timeline") : "Select a single clip to enable")
        }
    }

    @ViewBuilder
    private func audioTabContent() -> some View {
        let audios = selectedAudioClips
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            InspectorRow(icon: "speaker.wave.2.fill", label: "Audio")
            volumeRow(audios: audios)
            fadeRow(audios: audios, edge: .left)
            fadeRow(audios: audios, edge: .right)
        }

        if nonTextVisualClips.isEmpty {
            speedSection(clips: audios)
        }
    }

    @ViewBuilder
    private func volumeRow(audios: [Clip]) -> some View {
        propertyRow(label: "Volume") {
            ScrubbableNumberField(
                value: sharedClipValue(audios) { VolumeScale.dbFromLinear($0.volume) },
                range: VolumeScale.floorDb...VolumeScale.ceilingDb,
                format: "%.1f",
                valueSuffix: " dB",
                dragSensitivity: 0.3,
                fieldWidth: 56,
                displayTextOverride: { db in db <= VolumeScale.floorDb ? "-∞ dB" : nil },
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
        }
    }

    @ViewBuilder
    private func fadeRow(audios: [Clip], edge: FadeEdge) -> some View {
        let fps = editor.timeline.fps
        let minDuration = audios.map(\.durationFrames).min() ?? 0
        if minDuration > 0 {
            let value = sharedClipValue(audios) { frameToSeconds(frame: $0[keyPath: edge.fadeKeyPath], fps: fps) }
            propertyRow(label: edge.inspectorLabel) {
                ScrubbableNumberField(
                    value: value,
                    range: 0...frameToSeconds(frame: minDuration, fps: fps),
                    format: "%.2f",
                    valueSuffix: " s",
                    dragSensitivity: 0.02,
                    fieldWidth: 52,
                    onChanged: { sec in
                        let frames = secondsToFrame(seconds: sec, fps: fps)
                        for c in audios {
                            editor.applyClipProperty(clipId: c.id) {
                                $0[keyPath: edge.fadeKeyPath] = $0.clampedFade(frames, edge: edge)
                            }
                        }
                    }
                ) { sec in
                    let frames = secondsToFrame(seconds: sec, fps: fps)
                    commitToClips(audios, actionName: edge.inspectorLabel) { c in
                        editor.commitClipProperty(clipId: c.id) {
                            $0[keyPath: edge.fadeKeyPath] = $0.clampedFade(frames, edge: edge)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func speedSection(clips: [Clip]) -> some View {
        if !clips.isEmpty {
            InspectorRow(icon: "gauge.with.dots.needle.67percent", label: "Speed") {
                ScrubbableNumberField(
                    value: sharedClipValue(clips) { $0.speed },
                    range: 0.25...4.0,
                    format: "%.2f",
                    valueSuffix: "x",
                    dragSensitivity: 0.01,
                    fieldWidth: 50,
                    onChanged: { newVal in
                        for c in clips { editor.applyClipSpeed(clipId: c.id, newSpeed: newVal) }
                    }
                ) { newVal in
                    editor.commitClipSpeed(ids: clips.map(\.id), newSpeed: newVal)
                }
            }
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

    // MARK: - Transform Section

    @ViewBuilder
    private func transformSection(clips: [Clip]) -> some View {
        let single = clips.count == 1 ? clips.first : nil
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            transformHeader(clips: clips)
                .frame(height: KeyframesMetrics.headerHeight, alignment: .leading)
            if transformExpanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    animatableRow(label: "Position", clipId: single?.id, property: .position) {
                        InspectorPositionFields(clips: clips)
                    }
                    animatableRow(label: "Scale", clipId: single?.id, property: .scale) {
                        scaleScrubField(clips: clips)
                    }
                    animatableRow(label: "Opacity", clipId: single?.id, property: .opacity) {
                        opacityScrubField(clips: clips)
                    }
                }
                .padding(.leading, sectionContentIndent)
            }
        }
    }

    /// Property row with an optional keyframe stamp button after the value field.
    @ViewBuilder
    private func animatableRow<Fields: View>(
        label: String,
        clipId: String?,
        property: AnimatableProperty,
        @ViewBuilder fields: () -> Fields
    ) -> some View {
        propertyRow(label: label) {
            HStack(spacing: AppTheme.Spacing.sm) {
                fields()
                if let clipId {
                    keyframeStampButton(clipId: clipId, property: property)
                }
            }
        }
        .frame(height: KeyframesMetrics.rowHeight)
    }

    private func keyframeStampButton(clipId: String, property: AnimatableProperty) -> some View {
        let inRange = editor.clipFor(id: clipId)?.contains(timelineFrame: editor.currentFrame) ?? false
        let onKeyframe = editor.hasKeyframe(clipId: clipId, property: property, at: editor.currentFrame)
        return Button {
            if onKeyframe {
                editor.removeKeyframe(clipId: clipId, property: property, at: editor.currentFrame)
            } else {
                editor.stampKeyframe(clipId: clipId, property: property, frame: editor.currentFrame)
            }
        } label: {
            Image(systemName: onKeyframe ? "diamond.fill" : "diamond")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(onKeyframe ? AppTheme.Accent.timecodeColor : AppTheme.Text.tertiaryColor)
                .frame(width: KeyframesMetrics.stampButtonWidth, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!inRange)
        .opacity(inRange ? 1 : 0.4)
        .help(!inRange ? "Move playhead inside the clip"
              : onKeyframe ? "Remove keyframe at playhead"
              : "Add keyframe at playhead")
    }

    /// Indent property rows to align with the section header's title text
    private var sectionContentIndent: CGFloat { 20 }

    private func transformHeader(clips: [Clip]) -> some View {
        collapsibleHeader(
            icon: "arrow.up.and.down.and.arrow.left.and.right",
            title: "Transform",
            expanded: transformExpanded,
            onToggle: { transformExpanded.toggle() },
            resetHelp: transformExpanded ? "Reset transform" : nil,
            onReset: transformExpanded ? {
                commitToClips(clips, actionName: "Reset Transform") { c in
                    editor.commitClipProperty(clipId: c.id) {
                        $0.transform = Transform()
                        $0.opacity = 1
                        $0.opacityTrack = nil
                        $0.positionTrack = nil
                        $0.scaleTrack = nil
                    }
                }
            } : nil
        )
    }

    @ViewBuilder
    private func scaleScrubField(clips: [Clip]) -> some View {
        ScrubbableNumberField(
            value: sharedClipValue(clips) { $0.sizeAt(frame: editor.currentFrame).width },
            range: 0.01...5.0,
            displayMultiplier: 100,
            format: "%.0f",
            valueSuffix: "%",
            fieldWidth: 50,
            onChanged: { newVal in
                for c in clips { editor.applyScale(clipId: c.id, newScale: newVal) }
            }
        ) { newVal in
            editor.undoManager?.beginUndoGrouping()
            for c in clips { editor.commitScale(clipId: c.id, newScale: newVal) }
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName("Change Scale")
        }
    }

    @ViewBuilder
    private func opacityScrubField(clips: [Clip]) -> some View {
        ScrubbableNumberField(
            value: sharedClipValue(clips) { $0.opacityAt(frame: editor.currentFrame) },
            range: 0...1,
            displayMultiplier: 100,
            format: "%.0f",
            valueSuffix: "%",
            fieldWidth: 50,
            onChanged: { newVal in
                for c in clips { editor.applyOpacity(clipId: c.id, value: newVal) }
            }
        ) { newVal in
            editor.undoManager?.beginUndoGrouping()
            for c in clips { editor.commitOpacity(clipId: c.id, value: newVal) }
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName("Change Opacity")
        }
    }

    // MARK: - Section helpers

    private func collapsibleHeader(
        icon: String,
        title: String,
        expanded: Bool,
        onToggle: @escaping () -> Void,
        resetHelp: String? = nil,
        onReset: (() -> Void)? = nil
    ) -> some View {
        HStack {
            Button(action: onToggle) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    sectionTitleLabel(icon: icon, title: title)
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if let onReset {
                resetButton(onReset: onReset, help: resetHelp)
            }
        }
    }

    private func sectionTitleLabel(icon: String, title: String) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 16, alignment: .leading)
            Text(title)
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
    }

    private func resetButton(onReset: @escaping () -> Void, help: String?) -> some View {
        Button(action: onReset) {
            Image(systemName: "arrow.counterclockwise")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 22, height: 22)
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(help ?? "Reset")
    }

    private func propertyRow<Trailing: View>(
        label: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .fixedSize()
            Spacer()
            trailing()
        }
    }

    // MARK: - Crop Section

    @ViewBuilder
    private func cropSection(clip: Clip?) -> some View {
        let editing = editor.cropEditingActive && clip != nil
        let multi = clip == nil

        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                if multi {
                    sectionTitleLabel(icon: "crop.rotate", title: "Crop")
                        .help("Crop applies to one clip at a time")
                } else {
                    Button {
                        editor.cropEditingActive.toggle()
                    } label: {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            sectionTitleLabel(icon: "crop.rotate", title: "Crop")
                            Image(systemName: editing ? "chevron.down" : "chevron.right")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(editing ? "Exit crop editing" : "Edit crop")
                }

                Spacer()

                if let clip {
                    keyframeStampButton(clipId: clip.id, property: .crop)
                }
            }
            .frame(height: KeyframesMetrics.rowHeight)
            .opacity(multi ? 0.4 : 1)

            if editing, let clip {
                cropPresetRow(clip: clip)
                    .padding(.leading, sectionContentIndent)
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
            editor.commitCrop(clipId: clip.id, newCrop: Crop())
        default:
            guard let target = preset.pixelAspect else { return }
            editor.commitCrop(clipId: clip.id, newCrop: editor.cropFittingAspect(for: clip, targetPixelAspect: target))
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

private extension FadeEdge {
    var inspectorIcon: String { self == .left ? "arrow.up.right" : "arrow.down.right" }
    var inspectorLabel: String { self == .left ? "Fade In" : "Fade Out" }
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
