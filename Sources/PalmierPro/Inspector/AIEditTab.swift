import SwiftUI

struct AIEditTab: View {
    let asset: MediaAsset
    /// Clip id from the timeline.
    let clipId: String?
    @Environment(EditorViewModel.self) private var editor
    @State private var rerunError: String?
    @State private var replaceClipSource: Bool = false
    @State private var useTrimmedClip: Bool = true

    init(asset: MediaAsset, clipId: String? = nil) {
        self.asset = asset
        self.clipId = clipId
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                if hasScopeToggles {
                    aiSection(title: "Scope") {
                        if clipId != nil { replaceToggle }
                        if trimmedClipAvailable { trimmedClipToggle }
                    }
                }

                aiSection(title: "Actions") {
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
        .aiAccessGate()
    }

    private var hasScopeToggles: Bool {
        clipId != nil || trimmedClipAvailable
    }

    private var rerunDescription: String {
        guard let gen = asset.generationInput,
              let cost = CostEstimator.cost(for: gen) else {
            return "Regenerate with the same parameters"
        }
        return "Regenerate · \(CostEstimator.format(cost))"
    }

    private func aiSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.smMd) {
            Text(title.uppercased())
                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                .tracking(AppTheme.Tracking.wide)
                .foregroundStyle(AppTheme.Text.mutedColor)
            VStack(spacing: AppTheme.Spacing.smMd) {
                content()
            }
        }
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
        description: String
    ) -> some View {
        let availability = action.availability(
            for: asset,
            effectiveDurationOverride: effectiveDurationForAvailability
        )
        let canCall = AccountService.shared.isPaid
        let isEnabled = availability.isAvailable && canCall
        let disabledReason = canCall ? availability.reason : "Subscribe to Palmier to use AI"

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
            actionTrigger(action: action, title: title, isEnabled: isEnabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(disabledReason ?? "")
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
            .disabled(!isEnabled)
        case .createVideo:
            Menu(title) {
                Button("Set as first frame") { sendToVideo(asReference: false) }
                Button("Set as reference") { sendToVideo(asReference: true) }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .controlSize(.small)
            .disabled(!isEnabled)
        case .edit, .rerun:
            Button(title) {
                present(action)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!isEnabled)
        }
    }

    private func sendToVideo(asReference: Bool) {
        guard let model = VideoModelConfig.allModels.first(where: {
            !$0.requiresSourceVideo && (asReference ? $0.supportsReferences : $0.supportsFirstFrame)
        }) else { return }
        var stored = GenerationInput(prompt: "", model: model.id, duration: 0, aspectRatio: "", resolution: nil)
        if asReference { stored.referenceImageAssetIds = [asset.id] } else { stored.imageURLAssetIds = [asset.id] }
        seedPanel(stored: stored, defaultName: "Video from \(asset.name)", trimmed: nil)
    }

    private func present(_ action: EditAction) {
        switch action {
        case .upscale, .createVideo: break // handled via menu
        case .edit:
            guard let stored = editStoredInput() else { return }
            seedPanel(stored: stored, defaultName: "Edited \(asset.name)", trimmed: trimmedSourceIfEnabled())
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
                seedPanel(stored: stored, defaultName: nil, trimmed: nil)
            }
        }
    }

    private func editStoredInput() -> GenerationInput? {
        let modelId: String
        switch asset.type {
        case .video:
            guard let m = VideoModelConfig.allModels.first(where: { $0.requiresSourceVideo }) else { return nil }
            modelId = m.id
        case .image:
            guard let m = ImageModelConfig.nanoBananaPro else { return nil }
            modelId = m.id
        case .audio, .text:
            return nil
        }
        var stored = GenerationInput(prompt: "", model: modelId, duration: 0, aspectRatio: "", resolution: nil)
        stored.imageURLAssetIds = [asset.id]
        return stored
    }

    private func seedPanel(stored: GenerationInput, defaultName: String?, trimmed: TrimmedSource?) {
        editor.pendingEditReplacementClipId = (shouldReplace ? clipId : nil)
        editor.pendingEditTrimmedSource = trimmed
        editor.pendingPanelSeed = PendingPanelSeed(asset: asset, stored: stored, defaultName: defaultName)
        editor.showGenerationPanel = true
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
