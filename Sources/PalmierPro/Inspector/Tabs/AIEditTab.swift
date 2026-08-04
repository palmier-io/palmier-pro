import SwiftUI

struct AIEditTab: View {
    let asset: MediaAsset
    /// Clip id from the timeline.
    let clipId: String?
    let usesOwnScrollView: Bool
    @Environment(EditorViewModel.self) private var editor
    @Bindable private var account = AccountService.shared
    @State private var replaceClipSource: Bool = false
    @State private var useTrimmedClip: Bool = true
    @State private var placeAudioOnTimeline: Bool = true
    @State private var aiEnhanceExpanded: Bool = true
    @State private var aiAudioExpanded: Bool = true
    @State private var createVideoOptionsPresented = false

    init(asset: MediaAsset, clipId: String? = nil, usesOwnScrollView: Bool = true) {
        self.asset = asset
        self.clipId = clipId
        self.usesOwnScrollView = usesOwnScrollView
    }

    @ViewBuilder
    var body: some View {
        if usesOwnScrollView {
            ScrollView {
                panelContent
            }
        } else {
            panelContent
        }
    }

    private var panelContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            if trimmedClipAvailable {
                trimmedClipToggle
                    .padding(AppTheme.Spacing.smMd)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.Background.surfaceColor)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(AppTheme.Border.primaryColor)
                            .frame(height: AppTheme.BorderWidth.thin)
                    }
            }

            if isVisualClipContext {
                EditorPanelGroup(
                    L10n.string("AI Enhance"),
                    isExpanded: $aiEnhanceExpanded,
                    contentSpacing: AppTheme.Spacing.smMd,
                    contentInsets: actionGroupInsets
                ) {
                    if clipId != nil { replaceToggle }
                    visualActionGrid
                }
                .padding(.top, AppTheme.Spacing.xxs)
            }

            if asset.type == .video || asset.type == .audio {
                EditorPanelGroup(
                    L10n.string("AI Audio"),
                    isExpanded: $aiAudioExpanded,
                    contentSpacing: AppTheme.Spacing.smMd,
                    contentInsets: actionGroupInsets
                ) {
                    if clipId != nil {
                        audioPlacementToggle
                    }
                    audioActionGrid
                }
                .padding(.top, AppTheme.Spacing.xxs)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionGroupInsets: EdgeInsets {
        EdgeInsets(
            top: AppTheme.Spacing.xxs,
            leading: AppTheme.Spacing.smMd,
            bottom: AppTheme.Spacing.md,
            trailing: AppTheme.Spacing.smMd
        )
    }

    private var actionGridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: AppTheme.Spacing.sm),
            GridItem(.flexible(), spacing: AppTheme.Spacing.sm),
        ]
    }

    private var visualActionGrid: some View {
        LazyVGrid(columns: actionGridColumns, spacing: AppTheme.Spacing.sm) {
            actionTile(
                action: .upscale,
                icon: "sparkles.rectangle.stack",
                title: L10n.string("Upscale"),
                description: L10n.string("Enhance resolution or frame rate with AI")
            )
            actionTile(
                action: .edit,
                icon: "wand.and.stars",
                title: L10n.string("Edit"),
                description: L10n.string("Transform with a prompt or motion reference")
            )
            actionTile(
                action: .rerun,
                icon: "arrow.clockwise",
                title: L10n.string("Rerun"),
                description: L10n.string("Regenerate with the same parameters")
            )
            if asset.type == .video, VideoModelConfig.lipSync != nil {
                actionTile(
                    action: .lipSync,
                    icon: "mouth",
                    title: L10n.string("Lip Sync"),
                    description: L10n.string("Match mouth movement to replacement audio")
                )
            }
            if asset.type == .video {
                actionTile(
                    action: .reframe,
                    icon: "aspectratio",
                    title: L10n.string("Reframe"),
                    description: L10n.string("Change aspect ratio and extend the frame with AI")
                )
            }
            if asset.type == .image {
                actionTile(
                    action: .createVideo,
                    icon: "video.badge.plus",
                    title: L10n.string("Create Video"),
                    description: L10n.string("Use as first frame or reference")
                )
            }
        }
    }

    private var audioActionGrid: some View {
        LazyVGrid(columns: actionGridColumns, spacing: AppTheme.Spacing.sm) {
            if asset.type == .audio {
                actionTile(
                    action: .rerun,
                    icon: "arrow.clockwise",
                    title: L10n.string("Rerun"),
                    description: L10n.string("Regenerate with the same parameters")
                )
            }
            audioTransformActionTile(kind: .cleanup)
            audioTransformActionTile(kind: .dubbing)
            if isVisualClipContext, asset.type == .video {
                videoAudioActionTile(kind: .music)
                videoAudioActionTile(kind: .sfx)
            }
        }
    }

    private var isVisualClipContext: Bool {
        timelineClip?.mediaType.isVisual ?? asset.type.isVisual
    }

    // MARK: - Replace toggle

    private var replaceToggle: some View {
        scopeToggleRow(
            icon: "arrow.triangle.2.circlepath",
            label: L10n.string("Replace clip source"),
            help: L10n.string("Swap the clip's media when generation completes. Speed, volume, trim, and transform are preserved."),
            isOn: $replaceClipSource
        )
    }

    // MARK: - Trimmed clip toggle

    private var trimmedClipToggle: some View {
        scopeToggleRow(
            icon: "scissors",
            label: L10n.string("Use trimmed portion only"),
            help: L10n.string("Send only the visible clip range to the model, not the full source."),
            isOn: $useTrimmedClip
        )
    }

    private var audioPlacementToggle: some View {
        scopeToggleRow(
            icon: "plus.rectangle.on.rectangle",
            label: L10n.string("Place on timeline"),
            help: L10n.string("Add generated audio to an audio track at this clip's start."),
            isOn: $placeAudioOnTimeline
        )
    }

    private func scopeToggleRow(
        icon: String,
        label: String,
        help: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(isOn.wrappedValue ? AppTheme.Accent.primary : AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.Spacing.lgXl, alignment: .center)
            Text(L10n.string(key: label))
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer(minLength: AppTheme.Spacing.xs)
            Toggle(String(), isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityLabel(L10n.string(key: label))
                .accessibilityHint(L10n.string(key: help))
        }
        .help(L10n.string(key: help))
    }

    private var timelineClip: Clip? {
        guard let clipId else { return nil }
        return editor.clipFor(id: clipId)
    }

    private var trimmedClipAvailable: Bool {
        guard let clipId else { return false }
        return editor.aiEditTrimmedSource(clipId: clipId) != nil
    }

    private func trimmedSourceIfEnabled() -> TrimmedSource? {
        guard useTrimmedClip, let clipId else { return nil }
        return editor.aiEditTrimmedSource(clipId: clipId)
    }

    private var effectiveDurationForAvailability: Double? {
        trimmedSourceIfEnabled()?.durationSeconds
    }

    // MARK: - Action tiles

    @ViewBuilder
    private func actionTile(
        action: EditAction,
        icon: String,
        title: String,
        description: String,
        detail: String? = nil
    ) -> some View {
        let availability = action.availability(
            for: asset,
            effectiveDurationOverride: effectiveDurationForAvailability
        )
        let paidBlocked = action.requiresPaidPlan && !account.isPaid
        let isEnabled = availability.isAvailable && !paidBlocked && aiDisabledReason == nil
        let disabledReason = aiDisabledReason
            ?? (paidBlocked ? L10n.string("Requires a paid plan") : availability.reason)

        switch action {
        case .createVideo:
            actionTileSurface(
                description: description,
                isEnabled: isEnabled,
                disabledReason: disabledReason
            ) {
                actionButton(
                    icon: icon,
                    title: title,
                    detail: detail,
                    isEnabled: isEnabled,
                    showsMenuIndicator: true
                ) {
                    createVideoOptionsPresented = true
                }
                .popover(isPresented: $createVideoOptionsPresented, arrowEdge: .bottom) {
                    createVideoOptions
                }
            }
        case .upscale, .lipSync, .reframe, .edit, .generateMusic, .generateSFX, .rerun:
            actionTileSurface(
                description: description,
                isEnabled: isEnabled,
                disabledReason: disabledReason
            ) {
                actionButton(
                    icon: icon,
                    title: title,
                    detail: detail,
                    isEnabled: isEnabled
                ) {
                    present(action)
                }
            }
        }
    }

    private func videoAudioActionTile(kind: VideoToAudioEditKind) -> some View {
        actionTile(
            action: kind.action,
            icon: kind.iconName,
            title: L10n.string(key: kind.title),
            description: L10n.string(key: kind.description)
        )
    }

    private func audioTransformActionTile(kind: AudioTransformEditKind) -> some View {
        let availability = kind.availability(
            for: asset,
            effectiveDurationOverride: effectiveDurationForAvailability
        )
        let paidBlocked = kind.model?.paidOnly == true && !account.isPaid
        let isEnabled = availability.isAvailable && !paidBlocked && aiDisabledReason == nil
        let disabledReason = aiDisabledReason
            ?? (paidBlocked ? L10n.string("Requires a paid plan") : availability.reason)

        return actionTileSurface(
            description: L10n.string(key: kind.description),
            isEnabled: isEnabled,
            disabledReason: disabledReason
        ) {
            actionButton(
                icon: kind.iconName,
                title: L10n.string(key: kind.title),
                isEnabled: isEnabled
            ) {
                presentAudioTransform(kind)
            }
        }
    }

    private func actionTileSurface<Content: View>(
        description: String,
        isEnabled: Bool,
        disabledReason: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            .themedSurface(
                AppTheme.Background.raisedColor,
                cornerRadius: AppTheme.Radius.sm,
                borderWidth: AppTheme.BorderWidth.hairline
            )
            .disabled(!isEnabled)
            .help(disabledReason ?? description)
            .accessibilityHint(disabledReason ?? description)
    }

    private func actionButton(
        icon: String,
        title: String,
        detail: String? = nil,
        isEnabled: Bool,
        showsMenuIndicator: Bool = false,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(isEnabled ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
                    .frame(
                        width: AppTheme.IconSize.xs,
                        height: AppTheme.IconSize.xs,
                        alignment: .center
                    )
                Text(verbatim: title)
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(isEnabled ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                    .lineLimit(1)
                Spacer(minLength: AppTheme.Spacing.xs)
                if isEnabled, let detail {
                    Text(verbatim: detail)
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .lineLimit(1)
                }
                if showsMenuIndicator {
                    Image(systemName: "chevron.down")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(isEnabled ? AppTheme.Text.tertiaryColor : AppTheme.Text.mutedColor)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func presentAudioTransform(_ kind: AudioTransformEditKind) {
        if let clipId {
            editor.beginAIAudioTransform(
                clipId: clipId,
                kind: kind,
                useTrimmedClip: useTrimmedClip,
                placeOnTimeline: placeAudioOnTimeline
            )
        } else if let stored = EditSubmitter.audioTransformSeed(for: asset, kind: kind) {
            editor.seedGenerationPanel(asset: asset, stored: stored)
        }
    }

    private var createVideoOptions: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            createVideoOption(L10n.string("Set as first frame"), asReference: false)
            createVideoOption(L10n.string("Set as reference"), asReference: true)
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    private func createVideoOption(_ title: String, asReference: Bool) -> some View {
        Button {
            createVideoOptionsPresented = false
            sendToVideo(asReference: asReference)
        } label: {
            Text(verbatim: title)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
    }

    private func sendToVideo(asReference: Bool) {
        guard let stored = EditSubmitter.createVideoSeed(for: asset, asReference: asReference) else { return }
        seedPanel(stored: stored, trimmed: nil)
    }

    private func present(_ action: EditAction) {
        switch action {
        case .upscale:
            guard let model = UpscaleModelConfig.models(for: asset.type).first else { return }
            let trim = trimmedSourceIfEnabled()
            seedPanel(
                stored: EditSubmitter.upscaleSeed(for: asset, model: model, trimmedSource: trim),
                trimmed: trim
            )
        case .reframe:
            let trim = trimmedSourceIfEnabled()
            guard let stored = EditSubmitter.reframeSeed(for: asset, trimmedSource: trim) else { return }
            seedPanel(stored: stored, trimmed: trim)
        case .lipSync:
            guard let model = VideoModelConfig.lipSync,
                  let stored = EditSubmitter.lipSyncSeed(for: asset, model: model) else { return }
            seedPanel(stored: stored, trimmed: trimmedSourceIfEnabled())
        case .createVideo: break // handled via menu
        case .edit:
            guard let stored = EditSubmitter.editSeed(for: asset) else { return }
            seedPanel(stored: stored, trimmed: trimmedSourceIfEnabled())
        case .generateMusic:
            presentVideoAudio(kind: .music)
        case .generateSFX:
            presentVideoAudio(kind: .sfx)
        case .rerun:
            if let stored = asset.generationInput {
                seedPanel(stored: stored, trimmed: nil)
            }
        }
    }

    private func presentVideoAudio(kind: VideoToAudioEditKind) {
        guard let stored = EditSubmitter.videoAudioSeed(for: asset, kind: kind) else { return }
        seedPanel(
            stored: stored,
            trimmed: trimmedSourceIfEnabled(),
            allowsReplacement: false,
            audioPlacement: pendingAudioPlacement(actionName: kind.timelineActionName)
        )
    }

    private func seedPanel(
        stored: GenerationInput,
        trimmed: TrimmedSource?,
        allowsReplacement: Bool = true,
        audioPlacement: PendingAudioPlacement? = nil
    ) {
        editor.seedGenerationPanel(
            asset: asset,
            stored: stored,
            replacementClipId: allowsReplacement && shouldReplace ? clipId : nil,
            trimmedSource: trimmed,
            audioPlacement: audioPlacement
        )
    }

    private func pendingAudioPlacement(actionName: String) -> PendingAudioPlacement? {
        guard placeAudioOnTimeline, let clipId else { return nil }
        return editor.aiAudioPlacement(
            clipId: clipId,
            trimmedSource: trimmedSourceIfEnabled(),
            actionName: actionName
        )
    }

    private var shouldReplace: Bool { replaceClipSource && clipId != nil }

    private var aiDisabledReason: String? {
        if account.isMisconfigured { return L10n.string("AI is unavailable") }
        if !account.isSignedIn { return L10n.string("Sign in to use AI") }
        return nil
    }

}
