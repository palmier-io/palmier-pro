import AppKit
import SwiftUI

struct InspectorClipSelection {
    private(set) var textClips: [Clip] = []
    private(set) var nonTextVisualClips: [Clip] = []
    private(set) var audioClips: [Clip] = []
    private(set) var firstVisualClip: Clip?

    var clipCount: Int {
        textClips.count + nonTextVisualClips.count + audioClips.count
    }

    var firstAudioClip: Clip? { audioClips.first }

    static func resolve(timeline: Timeline, selectedIds: Set<String>) -> InspectorClipSelection {
        guard !selectedIds.isEmpty else { return InspectorClipSelection() }
        var selection = InspectorClipSelection()
        for track in timeline.tracks {
            for clip in track.clips where selectedIds.contains(clip.id) {
                if clip.mediaType == .audio {
                    selection.audioClips.append(clip)
                } else if clip.mediaType.isVisual {
                    if selection.firstVisualClip == nil {
                        selection.firstVisualClip = clip
                    }
                    if clip.mediaType == .text {
                        selection.textClips.append(clip)
                    } else {
                        selection.nonTextVisualClips.append(clip)
                    }
                }
            }
        }
        return selection
    }
}

struct InspectorView: View {
    @Environment(EditorViewModel.self) var editor

    enum ClipTab: Hashable {
        case text
        case textAnimate
        case video
        case effects
        case audio
        case multicam
        case ai

        var titleKey: String {
            switch self {
            case .text: L10n.key("Content")
            case .textAnimate: L10n.key("Animate")
            case .video: L10n.key("Video")
            case .effects: L10n.key("Adjust")
            case .audio: L10n.key("Audio")
            case .multicam: L10n.key("Multicam")
            case .ai: L10n.key("AI Edit")
            }
        }

        var systemImage: String {
            switch self {
            case .text: "text.alignleft"
            case .textAnimate: "diamond"
            case .video: "video"
            case .effects: "slider.horizontal.3"
            case .audio: "waveform"
            case .multicam: "square.grid.2x2"
            case .ai: "wand.and.stars"
            }
        }
    }

    @State private var preferredTab: ClipTab = .video
    @State private var assetInfoPresented = false
    @State private var assetFileSize: AssetFileSize?
    @State private var transformExpanded = true
    @State private var imageAdjustmentExpanded = true
    @State var audioLevelsExpanded = true
    @State var collapsedAdjustSections: Set<String> = ["Curves", "Color Wheels", "Hue Curves", "LUTs", "Effects"]
    @State var collapsedAdjustSubgroups: Set<String> = [
        "Detail", "Blur", "Motion Blur", "Vignette", "Film Grain", "Glow", "Chroma Key",
    ]
    @State private var customAspectRatioContext: CustomAspectRatioContext?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if editor.isMarqueeSelecting {
                marqueeSelectionSummary
            } else {
                resolvedInspectorContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: editor.selectedClipIds) { _, _ in
            editor.cancelChromaKeySampling()
            if !editor.isMarqueeSelecting { resolvePreferredTab() }
        }
        .onChange(of: editor.isMarqueeSelecting) { _, selecting in
            if !selecting { resolvePreferredTab() }
        }
        .onChange(of: preferredTab) { _, newTab in
            if newTab != .video { editor.cropEditingActive = false }
        }
        .onChange(of: editor.inspectorClipTabRequest) { _, request in
            guard let request else { return }
            preferredTab = request
            editor.inspectorClipTabRequest = nil
        }
        .sheet(item: $customAspectRatioContext) { context in
            CustomAspectRatioSheet(context: context)
        }
    }

    @ViewBuilder
    private var resolvedInspectorContent: some View {
        let selection = InspectorClipSelection.resolve(
            timeline: editor.timeline,
            selectedIds: editor.selectedClipIds
        )
        if selection.clipCount > 0 {
            clipInspectorContent(selection: selection)
        } else if let asset = selectedMediaAsset {
            mediaAssetInspectorContent(asset)
        } else {
            projectMetadataContent
        }
    }

    private var marqueeSelectionSummary: some View {
        VStack {
            Spacer()
            Text(L10n.string("\(editor.selectedClipIds.count) selected"))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resolvePreferredTab() {
        let isSingleText = editor.selectedClipIds.count == 1
            && editor.selectedClipIds.first.flatMap { editor.clipFor(id: $0) }?.mediaType == .text
        if isSingleText {
            preferredTab = .text
        } else if preferredTab == .text {
            preferredTab = .video
        }
        editor.cropEditingActive = false
    }

    // MARK: - Project Metadata

    private var projectMetadataContent: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            projectInspectorHeader
            ScrollView {
                EditorPanelGroup(
                    L10n.string("Canvas"),
                    contentSpacing: AppTheme.Spacing.sm,
                    contentInsets: EdgeInsets(
                        top: AppTheme.Spacing.smMd,
                        leading: AppTheme.Spacing.smMd + AppTheme.IconSize.xs + AppTheme.Spacing.sm,
                        bottom: AppTheme.Spacing.smMd,
                        trailing: AppTheme.Spacing.smMd
                    )
                ) {
                    menuMetadataRow(label: L10n.string("Resolution"), value: "\(editor.timeline.width) × \(editor.timeline.height)") { qualityMenuItems }
                    menuMetadataRow(label: L10n.string("Frame Rate"), value: "\(editor.timeline.fps) fps") { fpsMenuItems }
                    menuMetadataRow(label: L10n.string("Aspect Ratio"), value: CanvasAspectRatio.displayLabel(width: editor.timeline.width, height: editor.timeline.height)) { aspectMenuItems }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var projectInspectorHeader: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "movieclapper")
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                .accessibilityHidden(true)
            Text(L10n.string("Project Settings"))
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
            Spacer(minLength: AppTheme.Spacing.xs)
            Text(verbatim: projectDuration)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .panelHeaderBar()
    }

    private var projectDuration: String {
        formatDuration(Double(editor.timeline.totalFrames) / Double(editor.timeline.fps))
    }

    private func plainMetadataRow(
        label: String,
        value: String,
        valueHelp: String? = nil,
        truncate: Text.TruncationMode = .tail
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(L10n.string(key: label))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize()
            Spacer()
            Text(value)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(truncate)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
                .help(valueHelp ?? value)
                .padding(.horizontal, AppTheme.Spacing.xs)
        }
        .frame(height: AppTheme.IconSize.md)
    }

    private func menuMetadataRow<MenuContent: View>(
        label: String,
        value: String,
        @ViewBuilder menu: @escaping () -> MenuContent
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(L10n.string(key: label))
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize()
            Spacer()
            Menu {
                menu()
            } label: {
                EditorMenuValue(text: value)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
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
                    Text(verbatim: preset.label)
                    Spacer()
                    if preset.matches(width: editor.timeline.width, height: editor.timeline.height) {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
        Divider()
        Button(L10n.string("Custom…")) {
            customAspectRatioContext = CustomAspectRatioContext(
                timelineID: editor.activeTimelineId,
                width: editor.timeline.width,
                height: editor.timeline.height
            )
        }
    }

    @ViewBuilder
    private var fpsMenuItems: some View {
        ForEach([24, 25, 30, 50, 60], id: \.self) { fps in
            Button {
                editor.applyTimelineSettings(fps: fps, width: editor.timeline.width, height: editor.timeline.height)
            } label: {
                HStack {
                    Text(verbatim: "\(fps) fps")
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
                    Text(verbatim: preset.label)
                    Spacer()
                    if preset.matches(width: editor.timeline.width, height: editor.timeline.height) {
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }

    // MARK: - Clip Inspector

    private func availableTabs(
        for selection: InspectorClipSelection,
        resolvedClipAsset: MediaAsset?,
        selectedMulticamGroupId: String?
    ) -> [ClipTab] {
        let audios = selection.audioClips
        let texts = selection.textClips
        let nonText = selection.nonTextVisualClips
        let isTextOnly = !texts.isEmpty && nonText.isEmpty && audios.isEmpty

        var tabs: [ClipTab] = []
        if isTextOnly { tabs.append(.text); tabs.append(.textAnimate) }
        if !nonText.isEmpty {
            tabs.append(.video)
            tabs.append(.effects)
        }
        if !audios.isEmpty { tabs.append(.audio) }
        if selectedMulticamGroupId != nil { tabs.append(.multicam) }
        if aiEditEligible(selection: selection, resolvedClipAsset: resolvedClipAsset)
            && !AccountService.shared.isMisconfigured {
            tabs.append(.ai)
        }
        return tabs
    }

    private func selectedMulticamGroupId(for selection: InspectorClipSelection) -> String? {
        for clips in [selection.nonTextVisualClips, selection.audioClips] {
            for clip in clips {
                if let groupId = clip.multicamGroupId, editor.multicamGroup(id: groupId) != nil {
                    return groupId
                }
            }
        }
        return nil
    }

    private func aiEditEligible(
        selection: InspectorClipSelection,
        resolvedClipAsset: MediaAsset?
    ) -> Bool {
        let visualCount = selection.textClips.count + selection.nonTextVisualClips.count
        let audios = selection.audioClips
        guard resolvedClipAsset != nil else { return false }
        if visualCount == 0 { return audios.count == 1 }
        guard visualCount == 1, let visual = selection.firstVisualClip else { return false }
        if audios.isEmpty { return true }
        let partners = Set(editor.linkedPartnerIds(of: visual.id))
        return audios.allSatisfy { partners.contains($0.id) }
    }

    private func activeTab(in tabs: [ClipTab]) -> ClipTab? {
        return tabs.contains(preferredTab) ? preferredTab : tabs.first
    }

    private func resolvedClipAsset(for selection: InspectorClipSelection) -> MediaAsset? {
        guard let clip = selection.firstVisualClip ?? selection.firstAudioClip else { return nil }
        return editor.mediaAssets.first { $0.id == clip.mediaRef }
    }

    @ViewBuilder
    private func clipInspectorContent(selection: InspectorClipSelection) -> some View {
        let clipAsset = resolvedClipAsset(for: selection)
        let multicamGroupId = selectedMulticamGroupId(for: selection)
        let tabs = availableTabs(
            for: selection,
            resolvedClipAsset: clipAsset,
            selectedMulticamGroupId: multicamGroupId
        )
        let selectedTab = activeTab(in: tabs)
        VStack(spacing: 0) {
            if tabs.count > 1 {
                tabBar(tabs, selectedTab: selectedTab)
            }
            Group {
                if selectedTab == .ai, let asset = clipAsset {
                    AIEditTab(asset: asset, clipId: selection.firstVisualClip?.id ?? selection.firstAudioClip?.id)
                        .tourAnchor(.aiEditPanel)
                } else if selectedTab == .effects {
                    ScrollView { effectsTabContent(clips: selection.nonTextVisualClips) }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                            switch selectedTab {
                            case .text:
                                if !selection.textClips.isEmpty { TextTab(clips: selection.textClips) }
                            case .textAnimate:
                                if !selection.textClips.isEmpty { TextAnimateTab(clips: selection.textClips) }
                            case .video:
                                videoTabContent(
                                    clips: selection.nonTextVisualClips,
                                    audioClips: selection.audioClips
                                )
                            case .audio:
                                audioTabContent(
                                    audioClips: selection.audioClips,
                                    hasNonTextVisualClips: !selection.nonTextVisualClips.isEmpty
                                )
                            case .multicam:
                                if let groupId = multicamGroupId {
                                    MulticamTab(groupId: groupId)
                                }
                            case .effects, .ai, .none:
                                EmptyView()
                            }
                        }
                    }
                }
            }
        }
    }

    private func tabBar(_ tabs: [ClipTab], selectedTab: ClipTab?) -> some View {
        TitleTabBar(
            items: tabs.map {
                TitleTabBar.Item(titleKey: $0.titleKey, systemImage: $0.systemImage)
            },
            selected: selectedTab?.titleKey,
            tourAnchors: tabs.contains(.ai) ? [ClipTab.ai.titleKey: .aiEditTab] : [:]
        ) { title in
            if let tab = tabs.first(where: { $0.titleKey == title }) { preferredTab = tab }
        }
    }

    @ViewBuilder
    private func videoTabContent(clips: [Clip], audioClips: [Clip]) -> some View {
        transformSection(clips: clips)
        imageAdjustmentSection(clips: clips)
        speedSection(clips: (clips + audioClips).filter(\.supportsRetiming))
    }

    @ViewBuilder
    func speedSection(clips: [Clip]) -> some View {
        if !clips.isEmpty {
            EditorPanelGroup(L10n.string("Playback"), contentSpacing: AppTheme.Spacing.smMd) {
                propertyRow(
                    label: L10n.string("Speed"),
                    onReset: { editor.commitClipSpeed(ids: clips.map(\.id), newSpeed: 1) }
                ) {
                    ScrubbableNumberField(
                        value: sharedClipValue(clips) { $0.speed },
                        range: 0.25...4.0,
                        format: "%.2f",
                        valueSuffix: "x",
                        dragSensitivity: 0.01,
                        fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                        onChanged: { newVal in
                            for c in clips { editor.applyClipSpeed(clipId: c.id, newSpeed: newVal) }
                        }
                    ) { newVal in
                        editor.commitClipSpeed(ids: clips.map(\.id), newSpeed: newVal)
                    }
                }
            }
        }
    }

    func commitToClips(_ clips: [Clip], actionName: String, _ commit: (Clip) -> Void) {
        editor.undo.perform(actionName) {
            for c in clips { commit(c) }
        }
    }

    func commitPropertiesToClips(
        _ clips: [Clip],
        actionName: String,
        _ modify: (inout Clip) -> Void
    ) {
        editor.commitClipProperties(clipIds: clips.map(\.id), actionName: actionName, modify)
    }

    // MARK: - Transform Section

    @ViewBuilder
    private func transformSection(clips: [Clip]) -> some View {
        EditorPanelGroup(
            L10n.string("Transform"),
            isExpanded: $transformExpanded,
            onReset: {
                commitPropertiesToClips(clips, actionName: "Reset Transform") { clip in
                    clip.transform = editor.fitTransform(for: clip)
                    clip.opacity = 1
                    clip.opacityTrack = nil
                    clip.positionTrack = nil
                    clip.scaleTrack = nil
                    clip.rotationTrack = nil
                    clip.fadeInFrames = 0
                    clip.fadeOutFrames = 0
                    clip.fadeInInterpolation = .linear
                    clip.fadeOutInterpolation = .linear
                }
            }
        ) {
            transformRows(clips: clips, spacing: AppTheme.Spacing.smMd)
        }
    }

    private func transformRows(clips: [Clip], spacing: CGFloat) -> some View {
        let single = clips.count == 1 ? clips.first : nil
        return VStack(alignment: .leading, spacing: spacing) {
            animatableRow(
                label: L10n.string("Position"),
                clips: clips,
                property: .position,
                onReset: {
                    commitPropertiesToClips(clips, actionName: "Reset Position") { clip in
                        clip.transform.centerX = Transform().centerX
                        clip.transform.centerY = Transform().centerY
                        clip.positionTrack = nil
                    }
                }
            )
            animatableRow(
                label: L10n.string("Scale"),
                clips: clips,
                property: .scale,
                onReset: {
                    commitPropertiesToClips(clips, actionName: "Reset Scale") { clip in
                        let fitted = editor.fitTransform(for: clip)
                        clip.transform.width = fitted.width
                        clip.transform.height = fitted.height
                        clip.scaleTrack = nil
                    }
                }
            )
            animatableRow(
                label: L10n.string("Rotation"),
                clips: clips,
                property: .rotation,
                onReset: {
                    commitPropertiesToClips(clips, actionName: "Reset Rotation") { clip in
                        clip.transform.rotation = Transform().rotation
                        clip.rotationTrack = nil
                    }
                }
            )
            animatableRow(
                label: L10n.string("Opacity"),
                clips: clips,
                property: .opacity,
                onReset: {
                    commitPropertiesToClips(clips, actionName: "Reset Opacity") { clip in
                        clip.opacity = 1
                        clip.opacityTrack = nil
                    }
                }
            )
            cropRow(single: single)
            flipRow(clips: clips)
            blendRow(clips: clips)
        }
    }

    private func imageAdjustmentSection(clips: [Clip]) -> some View {
        EditorPanelGroup(
            L10n.string("Image Adjustment"),
            isExpanded: $imageAdjustmentExpanded,
            onReset: {
                commitPropertiesToClips(clips, actionName: "Reset Image Adjustment") { clip in
                    clip.edgeSoftness = 0
                    clip.edgeRounding = 0
                }
            }
        ) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
                edgeSoftnessRow(clips: clips)
                edgeRoundingRow(clips: clips)
            }
        }
    }

    private func edgeSoftnessRow(clips: [Clip]) -> some View {
        propertyRow(
            label: L10n.string("Edge Softness"),
            onReset: {
                commitPropertiesToClips(clips, actionName: "Reset Edge Softness") {
                    $0.edgeSoftness = 0
                }
            }
        ) {
            ScrubbableNumberField(
                value: sharedClipValue(clips) { $0.edgeSoftness },
                range: 0...1,
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { newValue in
                    editor.applyClipProperties(clipIds: clips.map(\.id)) {
                        $0.edgeSoftness = newValue
                    }
                }
            ) { newValue in
                editor.commitClipProperties(
                    clipIds: clips.map(\.id),
                    actionName: "Change Edge Softness"
                ) {
                    $0.edgeSoftness = newValue
                }
            }
        }
        .frame(height: AppTheme.EditorPanel.fieldMinHeight)
    }

    private func edgeRoundingRow(clips: [Clip]) -> some View {
        propertyRow(
            label: L10n.string("Edge Rounding"),
            onReset: {
                commitPropertiesToClips(clips, actionName: "Reset Edge Rounding") {
                    $0.edgeRounding = 0
                }
            }
        ) {
            ScrubbableNumberField(
                value: sharedClipValue(clips) { $0.edgeRounding },
                range: 0...1,
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { newValue in
                    editor.applyClipProperties(clipIds: clips.map(\.id)) {
                        $0.edgeRounding = newValue
                    }
                }
            ) { newValue in
                editor.commitClipProperties(
                    clipIds: clips.map(\.id),
                    actionName: "Change Edge Rounding"
                ) {
                    $0.edgeRounding = newValue
                }
            }
        }
        .frame(height: AppTheme.EditorPanel.fieldMinHeight)
    }

    // MARK: - Section helpers

    func sectionTitleLabel(title: String) -> some View {
        Text(L10n.string(key: title))
            .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .fixedSize()
    }

    func propertyRow<Trailing: View>(
        label: String,
        onReset: (() -> Void)? = nil,
        reservesKeyframeControls: Bool = false,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        InspectorRow(label: label, onReset: onReset) {
            if reservesKeyframeControls {
                HStack(spacing: AppTheme.Spacing.sm) {
                    trailing()
                    Color.clear.frame(width: KeyframeControlStrip.width)
                }
            } else {
                trailing()
            }
        }
    }

    func animatableRow(
        label: String,
        clips: [Clip],
        property: AnimatableProperty,
        onReset: @escaping () -> Void
    ) -> some View {
        propertyRow(label: label, onReset: onReset) {
            InspectorKeyframePropertyControl(clips: clips, property: property)
        }
    }

    // MARK: - Flip

    private func blendRow(clips: [Clip]) -> some View {
        let current = clips.first?.blendMode ?? .normal
        let mixed = clips.count > 1 && !clips.allSatisfy { ($0.blendMode ?? .normal) == current }
        return propertyRow(
            label: L10n.string("Blend"),
            onReset: {
                commitPropertiesToClips(clips, actionName: "Reset Blend Mode") {
                    $0.blendMode = nil
                }
            },
            reservesKeyframeControls: true
        ) {
            Menu {
                ForEach(BlendMode.allCases, id: \.self) { m in
                    Button(L10n.string(key: m.displayName)) {
                        commitPropertiesToClips(clips, actionName: "Blend Mode") {
                            $0.blendMode = (m == .normal ? nil : m)
                        }
                    }
                }
            } label: {
                EditorMenuValue(text: mixed ? "—" : L10n.string(key: current.displayName))
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize().focusable(false)
        }
        .frame(height: AppTheme.EditorPanel.fieldMinHeight)
    }

    @ViewBuilder
    private func flipRow(clips: [Clip]) -> some View {
        let activeH = clips.first?.transform.flipHorizontal ?? false
        let activeV = clips.first?.transform.flipVertical ?? false
        propertyRow(
            label: L10n.string("Flip"),
            onReset: {
                commitPropertiesToClips(clips, actionName: "Reset Flip") { clip in
                    clip.transform.flipHorizontal = false
                    clip.transform.flipVertical = false
                }
            },
            reservesKeyframeControls: true
        ) {
            HStack(spacing: AppTheme.Spacing.xs) {
                iconToggleButton(
                    systemName: "arrow.left.and.right",
                    isOn: activeH,
                    help: activeH ? L10n.string("Remove horizontal flip") : L10n.string("Flip horizontally")
                ) {
                    let newValue = !activeH
                    commitPropertiesToClips(clips, actionName: "Flip Horizontal") {
                        $0.transform.flipHorizontal = newValue
                    }
                }
                iconToggleButton(
                    systemName: "arrow.up.and.down",
                    isOn: activeV,
                    help: activeV ? L10n.string("Remove vertical flip") : L10n.string("Flip vertically")
                ) {
                    let newValue = !activeV
                    commitPropertiesToClips(clips, actionName: "Flip Vertical") {
                        $0.transform.flipVertical = newValue
                    }
                }
            }
        }
        .frame(height: AppTheme.EditorPanel.fieldMinHeight)
    }

    private func iconToggleButton(
        systemName: String,
        isOn: Bool,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                .foregroundStyle(isOn ? AppTheme.Accent.primary : AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .fill(AppTheme.Interaction.fill(isOn ? AppTheme.Opacity.subtle : 0))
                )
                .hoverHighlight()
        }
        .buttonStyle(.plain)
        .help(L10n.string(key: help))
    }

    // MARK: - Crop

    @ViewBuilder
    private func cropRow(single: Clip?) -> some View {
        let editing = editor.cropEditingActive && single != nil
        let disabled = single == nil
        propertyRow(
            label: L10n.string("Crop"),
            onReset: {
                guard let single else { return }
                editor.cropAspectLock = .free
                editor.commitClipProperty(clipId: single.id) {
                    $0.crop = Crop()
                    $0.cropTrack = nil
                }
            }
        ) {
            HStack(spacing: AppTheme.Spacing.sm) {
                iconToggleButton(
                    systemName: "crop",
                    isOn: editing,
                    help: disabled ? L10n.key("Crop applies to one clip at a time")
                          : editing ? L10n.key("Stop editing crop on canvas")
                          : L10n.key("Edit crop on canvas")
                ) {
                    editor.cropEditingActive.toggle()
                }
                .disabled(disabled)
                if editing, let clip = single, let ratio = editor.displayedCropAspectRatio(for: clip) {
                    HStack(spacing: AppTheme.Spacing.xxs) {
                        CropAspectFields(ratio: ratio) {
                            applyCropPreset(.locked(to: $0), on: clip)
                        }
                        cropMenu(single: clip, compact: true)
                    }
                } else {
                    cropMenu(single: single)
                }
                InspectorKeyframeControls(
                    clipId: single?.id,
                    property: .crop
                )
            }
        }
        .frame(height: AppTheme.EditorPanel.fieldMinHeight)
        .opacity(disabled ? 0.4 : 1)
    }

    private func cropMenu(single: Clip?, compact: Bool = false) -> some View {
        let active = editor.cropAspectLock
        return Menu {
            if let single {
                cropMenuItems(for: single)
            }
        } label: {
            if compact {
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.EditorPanel.fieldMinHeight)
                    .editorValueField()
                    .contentShape(Rectangle())
            } else {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Text(active.localizedLabel)
                        .font(.system(size: AppTheme.FontSize.sm, weight: .medium).monospacedDigit())
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .contentShape(Rectangle())
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(single == nil)
        .help(L10n.string("Choose a crop aspect"))
    }

    @ViewBuilder
    private func cropMenuItems(for clip: Clip) -> some View {
        let active = editor.cropAspectLock
        ForEach(CropAspectLock.presets, id: \.self) { preset in
            Button {
                applyCropPreset(preset, on: clip)
            } label: {
                if preset == active {
                    Label(preset.localizedLabel, systemImage: "checkmark")
                } else {
                    Text(preset.localizedLabel)
                }
            }
        }
    }

    private func applyCropPreset(_ preset: CropAspectLock, on clip: Clip) {
        let currentAspect = editor.displayedCropAspectRatio(for: clip, preferLockedRatio: false)?.pixelAspect
        editor.cropAspectLock = preset
        switch preset {
        case .free:
            break
        case .original:
            editor.commitCrop(clipId: clip.id, newCrop: Crop())
        default:
            guard let target = preset.pixelAspect else { return }
            guard currentAspect.map({ abs($0 - target) > 1e-4 }) ?? true else { return }
            editor.commitCrop(clipId: clip.id, newCrop: editor.cropFittingAspect(for: clip, targetPixelAspect: target))
        }
    }

    // MARK: - Media Asset Inspector

    private func mediaAssetInspectorContent(_ asset: MediaAsset) -> some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            assetInspectorHeader(asset)
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                    if let gen = asset.generationInput {
                        inputSection(gen)
                    }
                    AIEditTab(asset: asset, usesOwnScrollView: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func assetInspectorHeader(_ asset: MediaAsset) -> some View {
        let infoLabel = assetInfoPresented ? L10n.string("Hide Info") : L10n.string("Show Info")
        return HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: asset.type.sfSymbolName)
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                .accessibilityHidden(true)
            Text(verbatim: asset.name)
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: asset.name))
            Spacer(minLength: AppTheme.Spacing.xs)
            Button {
                assetInfoPresented.toggle()
            } label: {
                Image(systemName: assetInfoPresented ? "info.circle.fill" : "info.circle")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(assetInfoPresented ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
            }
            .buttonStyle(.plain)
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            .help(infoLabel)
            .accessibilityLabel(infoLabel)
            .popover(isPresented: $assetInfoPresented, arrowEdge: .top) {
                assetFileInfoContent(asset)
                    .frame(width: AppTheme.EditorPanel.defaultWidth)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .panelHeaderBar()
    }

    private func assetFileInfoContent(_ asset: MediaAsset) -> some View {
        fileSection(asset)
            .task(id: asset.url) {
                let url = asset.url
                assetFileSize = nil
                let formattedSize = await Self.formattedFileSize(for: url)
                guard !Task.isCancelled, asset.url == url else { return }
                assetFileSize = formattedSize.map { AssetFileSize(url: url, formattedValue: $0) }
            }
    }

    private func fileSection(_ asset: MediaAsset) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            plainMetadataRow(label: L10n.string("Type"), value: asset.type.localizedTrackLabel)
            if asset.type != .audio, let width = asset.sourceWidth, let height = asset.sourceHeight {
                plainMetadataRow(label: L10n.string("Dimensions"), value: "\(width) × \(height)")
            }
            if let fps = asset.sourceFPS, fps > 0 {
                plainMetadataRow(
                    label: "FPS",
                    value: "\(fps.formatted(.number.precision(.fractionLength(0...3)))) fps"
                )
            }
            if asset.duration > 0 && asset.type != .image {
                plainMetadataRow(label: L10n.string("Duration"), value: formatDuration(asset.duration))
            }
            if let fileSize = assetFileSize, fileSize.url == asset.url {
                plainMetadataRow(label: L10n.string("Size"), value: fileSize.formattedValue)
            }
            plainMetadataRow(
                label: L10n.string("Path"),
                value: asset.url.path,
                truncate: .middle
            )
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inputSection(_ gen: GenerationInput) -> some View {
        let hasReferences = GenerationReferencesStrip.hasResolvableReferences(gen, in: editor.mediaAssets)
        let metadata = inputMetadataSummary(gen)
        return EditorPanelGroup(
            L10n.string("Generation Input"),
            contentSpacing: AppTheme.Spacing.zero,
            contentInsets: EdgeInsets(
                top: AppTheme.Spacing.xxs,
                leading: AppTheme.Spacing.smMd,
                bottom: AppTheme.Spacing.md,
                trailing: AppTheme.Spacing.smMd
            )
        ) {
            if hasReferences {
                GenerationReferencesStrip(generationInput: gen)
            }
            if !gen.prompt.isEmpty || !metadata.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    if !gen.prompt.isEmpty {
                        promptSection(prompt: gen.prompt)
                    }
                    if !gen.prompt.isEmpty, !metadata.isEmpty {
                        Rectangle()
                            .fill(AppTheme.Border.subtleColor)
                            .frame(height: AppTheme.BorderWidth.hairline)
                    }
                    if !metadata.isEmpty {
                        Text(verbatim: metadata)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .textSelection(.enabled)
                            .help(Text(verbatim: metadata))
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.smMd)
                .padding(.vertical, AppTheme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .themedSurface(
                    AppTheme.Background.raisedColor,
                    cornerRadius: AppTheme.Radius.sm,
                    borderWidth: AppTheme.BorderWidth.hairline
                )
                .padding(.top, hasReferences ? AppTheme.Spacing.md : AppTheme.Spacing.zero)
            }
        }
        .padding(.top, AppTheme.Spacing.xxs)
    }

    private func promptSection(prompt: String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Prompt"))
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Spacer()
                PromptCopyButton(text: prompt)
            }
            Text(verbatim: prompt)
                .font(.system(size: AppTheme.FontSize.sm))
                .lineSpacing(AppTheme.Spacing.xxs)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inputMetadataSummary(_ gen: GenerationInput) -> String {
        var values = [ModelRegistry.displayName(for: gen.model)]
        if gen.draft == true { values.append(L10n.string("Draft")) }
        if !gen.aspectRatio.isEmpty {
            values.append(ImageModelConfig.aspectRatioDisplayLabel(gen.aspectRatio))
        }
        if let resolution = gen.resolution, !resolution.isEmpty {
            values.append(resolution)
        }
        if gen.duration > 0 {
            values.append("\(gen.duration)s")
        }
        return values.joined(separator: " · ")
    }

    // MARK: - Helpers

    private var selectedMediaAsset: MediaAsset? {
        guard editor.selectedMediaAssetIds.count == 1,
              let id = editor.selectedMediaAssetIds.first else { return nil }
        return editor.mediaAssets.first { $0.id == id }
    }

    private struct AssetFileSize {
        let url: URL
        let formattedValue: String
    }

    @concurrent
    private static func formattedFileSize(for url: URL) async -> String? {
        guard !Task.isCancelled else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        guard !Task.isCancelled else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let mins = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, mins, secs)
        }
        return String(format: "%d:%02d", mins, secs)
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
        .help(copied ? L10n.string("Copied") : L10n.string("Copy prompt"))
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
