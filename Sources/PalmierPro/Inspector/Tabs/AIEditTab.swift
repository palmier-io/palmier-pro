import SwiftUI

struct AIEditTab: View {
    let asset: MediaAsset
    /// Clip id from the timeline.
    let clipId: String?
    @Environment(EditorViewModel.self) private var editor
    @Bindable private var account = AccountService.shared
    @State private var replaceClipSource: Bool = false
    @State private var useTrimmedClip: Bool = true
    @State private var placeAudioOnTimeline: Bool = true
    @State private var aiEnhanceExpanded: Bool = true
    @State private var aiAudioExpanded: Bool = true

    init(asset: MediaAsset, clipId: String? = nil) {
        self.asset = asset
        self.clipId = clipId
    }

    var body: some View {
        ScrollView {
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
                    EditorPanelGroup(L10n.string("AI Enhance"), isExpanded: $aiEnhanceExpanded, contentSpacing: AppTheme.Spacing.smMd) {
                        if clipId != nil { replaceToggle }
                        actionRow(
                            action: .upscale,
                            icon: "sparkles.rectangle.stack",
                            title: L10n.string("Upscale"),
                            description: L10n.string("Enhance resolution or frame rate with AI")
                        )
                        actionRow(
                            action: .edit,
                            icon: "wand.and.stars",
                            title: L10n.string("Edit"),
                            description: L10n.string("Transform with a prompt or motion reference")
                        )
                        actionRow(
                            action: .rerun,
                            icon: "arrow.clockwise",
                            title: L10n.string("Rerun"),
                            description: L10n.string("Regenerate with the same parameters"),
                            detail: rerunCost
                        )
                        if asset.type == .video, let model = VideoModelConfig.lipSync {
                            actionRow(
                                action: .lipSync,
                                icon: "mouth",
                                title: L10n.string("Lip Sync"),
                                description: L10n.string("Match mouth movement to replacement audio"),
                                detail: model.sourceDurationLimitLabel.map { L10n.string("Up to \($0)") },
                                triggerTitle: L10n.string("Choose Audio")
                            )
                        }
                        if asset.type == .video {
                            actionRow(
                                action: .reframe,
                                icon: "aspectratio",
                                title: L10n.string("Reframe"),
                                description: L10n.string("Change aspect ratio and extend the frame with AI"),
                                detail: VideoModelConfig.reframe?.sourceDurationLimitLabel
                                    .map { L10n.string("Up to \($0)") }
                            )
                        }
                        if asset.type == .image {
                            actionRow(
                                action: .createVideo,
                                icon: "video.badge.plus",
                                title: L10n.string("Create Video"),
                                description: L10n.string("Use as first frame or reference")
                            )
                        }
                    }
                }

                if asset.type == .video || asset.type == .audio {
                    EditorPanelGroup(L10n.string("AI Audio"), isExpanded: $aiAudioExpanded, contentSpacing: AppTheme.Spacing.smMd) {
                        if showsAudioOutputOptions {
                            audioPlacementToggle
                        }
                        if asset.type == .audio {
                            actionRow(
                                action: .rerun,
                                icon: "arrow.clockwise",
                                title: L10n.string("Rerun"),
                                description: L10n.string("Regenerate with the same parameters"),
                                detail: rerunCost
                            )
                        }
                        if clipId != nil {
                            audioTransformActionRow(kind: .cleanup)
                            audioTransformActionRow(kind: .dubbing)
                        }
                        if isVisualClipContext, asset.type == .video {
                            videoAudioActionRow(kind: .music)
                            videoAudioActionRow(kind: .sfx)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var showsAudioOutputOptions: Bool {
        (asset.type == .video || asset.type == .audio) && clipId != nil
    }

    private var isVisualClipContext: Bool {
        timelineClip?.mediaType.isVisual ?? asset.type.isVisual
    }

    private var rerunCost: String? {
        guard let gen = asset.generationInput,
              let cost = CostEstimator.cost(for: gen) else {
            return nil
        }
        return CostEstimator.localizedDescription(cost)
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

    // MARK: - Action row

    @ViewBuilder
    private func actionRow(
        action: EditAction,
        icon: String,
        title: String,
        description: String,
        detail: String? = nil,
        triggerTitle: String? = nil
    ) -> some View {
        let availability = action.availability(
            for: asset,
            effectiveDurationOverride: effectiveDurationForAvailability
        )
        let paidBlocked = action.requiresPaidPlan && !account.isPaid
        let isEnabled = availability.isAvailable && !paidBlocked && aiDisabledReason == nil
        let disabledReason = aiDisabledReason
            ?? (paidBlocked ? L10n.string("Requires a paid plan") : availability.reason)

        descriptiveActionRow(
            icon: icon,
            title: title,
            description: description,
            detail: detail,
            isEnabled: isEnabled,
            disabledReason: disabledReason
        ) {
            actionTrigger(action: action, title: triggerTitle ?? title, isEnabled: isEnabled)
        }
    }

    private func videoAudioActionRow(kind: VideoToAudioEditKind) -> some View {
        actionRow(
            action: kind.action,
            icon: kind.iconName,
            title: L10n.string(key: kind.title),
            description: L10n.string(key: kind.description),
            triggerTitle: L10n.string("Generate")
        )
    }

    @ViewBuilder
    private func audioTransformActionRow(kind: AudioTransformEditKind) -> some View {
        let model = kind.model
        let availability = kind.availability(
            for: asset,
            effectiveDurationOverride: effectiveDurationForAvailability
        )
        let paidBlocked = model?.paidOnly == true && !account.isPaid
        let isEnabled = availability.isAvailable && !paidBlocked && aiDisabledReason == nil
        let disabledReason = aiDisabledReason
            ?? (paidBlocked ? L10n.string("Requires a paid plan") : availability.reason)

        descriptiveActionRow(
            icon: kind.iconName,
            title: L10n.string(key: kind.title),
            description: L10n.string(key: kind.description),
            isEnabled: isEnabled,
            disabledReason: disabledReason
        ) {
            Button(L10n.string("Generate")) {
                presentAudioTransform(kind)
            }
            .buttonStyle(.capsule(.secondary))
            .controlSize(.small)
            .disabled(!isEnabled)
        }
    }

    private func descriptiveActionRow<Trailing: View>(
        icon: String,
        title: String,
        description: String,
        detail: String? = nil,
        isEnabled: Bool,
        disabledReason: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(isEnabled ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
                .frame(width: AppTheme.Spacing.lgXl, alignment: .center)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(L10n.string(key: title))
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(isEnabled ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                if let disabledReason {
                    Text(disabledReason)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: AppTheme.Spacing.xs)
            if isEnabled, let detail {
                Text(detail)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
            }
            trailing()
                .accessibilityHint(disabledReason ?? description)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func presentAudioTransform(_ kind: AudioTransformEditKind) {
        guard let clipId else { return }
        editor.beginAIAudioTransform(
            clipId: clipId,
            kind: kind,
            useTrimmedClip: useTrimmedClip,
            placeOnTimeline: placeAudioOnTimeline
        )
    }

    @ViewBuilder
    private func actionTrigger(action: EditAction, title: String, isEnabled: Bool) -> some View {
        switch action {
        case .upscale:
            Button(title) {
                present(action)
            }
            .buttonStyle(.capsule(.secondary))
            .controlSize(.small)
            .disabled(!isEnabled)
        case .createVideo:
            Menu(title) {
                Button(L10n.string("Set as first frame")) { sendToVideo(asReference: false) }
                Button(L10n.string("Set as reference")) { sendToVideo(asReference: true) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            .disabled(!isEnabled)
        case .lipSync, .reframe, .edit, .generateMusic, .generateSFX, .rerun:
            Button(title) {
                present(action)
            }
            .buttonStyle(.capsule(.secondary))
            .controlSize(.small)
            .disabled(!isEnabled)
        }
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
            guard let stored = EditSubmitter.reframeSeed(for: asset) else { return }
            seedPanel(stored: stored, trimmed: trimmedSourceIfEnabled())
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
