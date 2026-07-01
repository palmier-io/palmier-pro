import SwiftUI

struct AIEditTab: View {
    let asset: MediaAsset
    /// Clip id from the timeline.
    let clipId: String?
    @Environment(EditorViewModel.self) private var editor
    @Bindable private var account = AccountService.shared
    @State private var rerunError: String?
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
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                if hasScopeToggles {
                    InspectorSection("Scope", contentSpacing: AppTheme.Spacing.smMd) {
                        if clipId != nil { replaceToggle }
                        if trimmedClipAvailable { trimmedClipToggle }
                    }
                }

                InspectorSection("AI Enhance", isExpanded: $aiEnhanceExpanded, contentSpacing: AppTheme.Spacing.smMd) {
                    actionRow(
                        action: .upscale,
                        icon: "sparkles.rectangle.stack",
                        title: "Upscale",
                        description: "Enhance resolution with AI"
                    )
                    actionRow(
                        action: .edit,
                        icon: "wand.and.stars",
                        title: "Edit",
                        description: "Transform with a prompt or motion reference"
                    )
                    actionRow(
                        action: .rerun,
                        icon: "arrow.clockwise",
                        title: "Rerun",
                        description: rerunDescription
                    )
                    if asset.type == .image {
                        actionRow(
                            action: .createVideo,
                            icon: "video.badge.plus",
                            title: "Create Video",
                            description: "Use as first frame or reference"
                        )
                    }
                }

                if asset.type == .video {
                    InspectorSection("AI Audio", isExpanded: $aiAudioExpanded, contentSpacing: AppTheme.Spacing.smMd) {
                        if showsAudioOutputOptions {
                            audioPlacementToggle
                        }
                        videoAudioActionRow(kind: .music)
                        videoAudioActionRow(kind: .sfx)
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert("Rerun failed", isPresented: Binding(
            get: { rerunError != nil },
            set: { if !$0 { rerunError = nil } }
        )) {
            Button("Dismiss") { rerunError = nil }
        } message: {
            Text(rerunError ?? "")
        }
    }

    private var hasScopeToggles: Bool {
        clipId != nil || trimmedClipAvailable
    }

    private var showsAudioOutputOptions: Bool {
        asset.type == .video && clipId != nil
    }

    private var rerunDescription: String {
        guard let gen = asset.generationInput,
              let cost = CostEstimator.cost(for: gen) else {
            return "Regenerate with the same parameters"
        }
        return "Regenerate · \(CostEstimator.format(cost))"
    }

    // MARK: - Replace toggle

    private var replaceToggle: some View {
        scopeToggleRow(
            icon: "arrow.triangle.2.circlepath",
            label: "Replace clip source",
            help: "Swap the clip's media when generation completes. Speed, volume, trim, and transform are preserved.",
            isOn: $replaceClipSource
        )
    }

    // MARK: - Trimmed clip toggle

    private var trimmedClipToggle: some View {
        scopeToggleRow(
            icon: "scissors",
            label: "Use trimmed portion only",
            help: "Send only the visible clip range to the model, not the full source.",
            isOn: $useTrimmedClip
        )
    }

    private var audioPlacementToggle: some View {
        scopeToggleRow(
            icon: "plus.rectangle.on.rectangle",
            label: "Place on timeline",
            help: "Add generated audio to an audio track at this clip's start.",
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
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer(minLength: AppTheme.Spacing.xs)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .help(help)
    }

    private var timelineClip: Clip? {
        guard let clipId else { return nil }
        return editor.clipFor(id: clipId)
    }

    private var trimmedClipAvailable: Bool {
        guard asset.type == .video, let clip = timelineClip else { return false }
        return clip.trimStartFrame > 0 || clip.trimEndFrame > 0
    }

    private func trimmedSourceIfEnabled() -> TrimmedSource? {
        guard trimmedClipAvailable, useTrimmedClip, let clip = timelineClip else { return nil }
        return TrimmedSource(
            sourceURL: asset.url,
            trimStartFrame: clip.trimStartFrame,
            trimEndFrame: clip.trimEndFrame,
            sourceFramesConsumed: clip.sourceFramesConsumed,
            fps: editor.timeline.fps
        )
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
        triggerTitle: String? = nil
    ) -> some View {
        let availability = action.availability(
            for: asset,
            effectiveDurationOverride: effectiveDurationForAvailability
        )
        let paidBlocked = (action == .upscale || action == .edit) && !account.isPaid
        let isEnabled = availability.isAvailable && !paidBlocked
        let disabledReason = paidBlocked ? "Requires a paid plan" : availability.reason

        HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(isEnabled ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
                .frame(width: AppTheme.Spacing.lgXl, alignment: .center)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(isEnabled ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                Text(disabledReason ?? description)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(disabledReason != nil ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AppTheme.Spacing.sm)
            actionTrigger(action: action, title: triggerTitle ?? title, isEnabled: isEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(disabledReason ?? "")
    }

    private func videoAudioActionRow(kind: VideoToAudioEditKind) -> some View {
        actionRow(
            action: kind.action,
            icon: kind.iconName,
            title: kind.title,
            description: kind.description,
            triggerTitle: "Generate"
        )
    }

    @ViewBuilder
    private func actionTrigger(action: EditAction, title: String, isEnabled: Bool) -> some View {
        switch action {
        case .upscale:
            Menu(title) {
                ForEach(UpscaleModelConfig.models(for: asset.type)) { model in
                    Button {
                        runUpscale(model)
                    } label: {
                        Text(upscaleLabel(for: model))
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .disabled(!isEnabled || !account.aiAllowed)
            .help(account.aiAllowed ? "" : "Sign in to upscale")
        case .createVideo:
            Menu(title) {
                Button("Set as first frame") { sendToVideo(asReference: false) }
                Button("Set as reference") { sendToVideo(asReference: true) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .disabled(!isEnabled)
        case .edit, .generateMusic, .generateSFX, .rerun:
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
        case .upscale, .createVideo: break // handled via menu
        case .edit:
            guard let stored = EditSubmitter.editSeed(for: asset) else { return }
            seedPanel(stored: stored, trimmed: trimmedSourceIfEnabled())
        case .generateMusic:
            presentVideoAudio(kind: .music)
        case .generateSFX:
            presentVideoAudio(kind: .sfx)
        case .rerun:
            let modelId = asset.generationInput?.model ?? ""
            if UpscaleModelConfig.allIds.contains(modelId) {
                do {
                    markReplacementPendingIfNeeded()
                    _ = try EditSubmitter.rerun(
                        asset: asset, editor: editor,
                        onComplete: replacementCompletion(),
                        onFailure: replacementFailure()
                    )
                } catch {
                    unmarkReplacementPendingIfNeeded()
                    rerunError = error.localizedDescription
                }
            } else if let stored = asset.generationInput {
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
        guard placeAudioOnTimeline, let clip = timelineClip else { return nil }
        let spanSeconds = trimmedSourceIfEnabled()?.durationSeconds
            ?? (asset.duration > 0
                ? asset.duration
                : Double(clip.durationFrames) / Double(max(1, editor.timeline.fps)))
        return PendingAudioPlacement(
            startFrame: clip.startFrame,
            spanSeconds: max(spanSeconds, 1 / Double(max(1, editor.timeline.fps))),
            actionName: actionName
        )
    }

    private func upscaleLabel(for model: UpscaleModelConfig) -> String {
        let seconds = Int((effectiveDurationForAvailability ?? asset.duration).rounded())
        let cost = CostEstimator.upscaleCost(model: model, durationSeconds: max(1, seconds))
        return "\(model.displayName) · \(model.speed) · \(CostEstimator.format(cost))"
    }

    private func runUpscale(_ model: UpscaleModelConfig) {
        markReplacementPendingIfNeeded()
        let trim = trimmedSourceIfEnabled()
        _ = EditSubmitter.submitUpscale(
            asset: asset, model: model, editor: editor,
            trimmedSource: trim,
            onComplete: replacementCompletion(resetTrim: trim != nil),
            onFailure: replacementFailure()
        )
    }

    private var shouldReplace: Bool { replaceClipSource && clipId != nil }

    private func markReplacementPendingIfNeeded() {
        guard shouldReplace, let clipId else { return }
        editor.markPendingReplacement(clipId: clipId)
    }

    private func unmarkReplacementPendingIfNeeded() {
        guard shouldReplace, let clipId else { return }
        editor.clearPendingReplacement(clipId: clipId)
    }

    private func replacementCompletion(resetTrim: Bool = false) -> (@MainActor (MediaAsset) -> Void)? {
        guard shouldReplace, let clipId else { return nil }
        // if generating more than one image, only replace with the first one
        let fired = FirstOnlyFlag()
        return { [weak editor] newAsset in
            guard fired.fire() else { return }
            editor?.replaceClipMediaRef(clipId: clipId, newAssetId: newAsset.id, resetTrim: resetTrim)
            editor?.clearPendingReplacement(clipId: clipId)
        }
    }

    private func replacementFailure() -> (@MainActor () -> Void)? {
        guard shouldReplace, let clipId else { return nil }
        return { [weak editor] in
            editor?.clearPendingReplacement(clipId: clipId)
        }
    }

}
