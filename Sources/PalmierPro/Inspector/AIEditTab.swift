import SwiftUI

struct AIEditTab: View {
    let asset: MediaAsset
    /// Clip id from the timeline.
    let clipId: String?
    @Environment(EditorViewModel.self) private var editor
    @State private var service = GenerationService()
    @State private var rerunError: String?
    @State private var replaceClipSource: Bool = false
    @State private var useTrimmedClip: Bool = true

    init(asset: MediaAsset, clipId: String? = nil) {
        self.asset = asset
        self.clipId = clipId
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if !service.hasApiKey {
                    apiKeyBanner
                }

                if clipId != nil {
                    replaceToggle
                }

                if trimmedClipAvailable {
                    trimmedClipToggle
                }

                actionCard(
                    action: .upscale,
                    icon: "arrow.up.right.square",
                    title: "Upscale",
                    description: "Enhance resolution with AI"
                )
                actionCard(
                    action: .edit,
                    icon: "wand.and.stars",
                    title: "Edit",
                    description: "Transform with a prompt or motion reference"
                )
                actionCard(
                    action: .rerun,
                    icon: "arrow.clockwise",
                    title: "Rerun",
                    description: "Regenerate with the same parameters"
                )
            }
            .padding(AppTheme.Spacing.md)
        }
        .alert("Rerun failed", isPresented: Binding(
            get: { rerunError != nil },
            set: { if !$0 { rerunError = nil } }
        )) {
            Button("OK") { rerunError = nil }
        } message: {
            Text(rerunError ?? "")
        }
    }

    // MARK: - Replace toggle

    private var replaceToggle: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(replaceClipSource ? Color.accentColor : AppTheme.Text.tertiaryColor)
            Text("Replace clip source")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer(minLength: AppTheme.Spacing.xs)
            Toggle("", isOn: $replaceClipSource)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .help("Swap the clip's media when generation completes. Speed, volume, trim, and transform are preserved.")
    }

    // MARK: - Trimmed clip toggle

    private var trimmedClipToggle: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "scissors")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(useTrimmedClip ? Color.accentColor : AppTheme.Text.tertiaryColor)
            Text("Use trimmed portion only")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer(minLength: AppTheme.Spacing.xs)
            Toggle("", isOn: $useTrimmedClip)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .help("Send only the visible clip range to the model, not the full source.")
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

    // MARK: - API key banner

    private var apiKeyBanner: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(.orange)
            Text("Set a fal.ai API key in the Generation panel to enable AI actions.")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.orange.opacity(0.08))
        )
    }

    // MARK: - Action card

    @ViewBuilder
    private func actionCard(
        action: EditAction,
        icon: String,
        title: String,
        description: String
    ) -> some View {
        let availability = action.availability(
            for: asset,
            effectiveDurationOverride: effectiveDurationForAvailability
        )
        let isEnabled = availability.isAvailable && service.hasApiKey
        let disabledReason = service.hasApiKey ? availability.reason : "API key required"

        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(isEnabled ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                        .foregroundStyle(isEnabled ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                    Text(disabledReason ?? description)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(disabledReason != nil ? AppTheme.Text.secondaryColor : AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppTheme.Spacing.sm)
                if action == .upscale {
                    Menu(title) {
                        ForEach(UpscaleModelConfig.models(for: asset.type)) { model in
                            Button {
                                runUpscale(model)
                            } label: {
                                Text("\(model.displayName) · \(model.speed)")
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .controlSize(.small)
                    .disabled(!isEnabled)
                } else {
                    Button(title) {
                        present(action)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!isEnabled)
                }
            }

            if action == .rerun, availability.isAvailable, let gen = asset.generationInput {
                rerunParameters(gen)
                    .padding(.leading, 24)
                    .padding(.top, AppTheme.Spacing.xs)
            }
        }
        .padding(AppTheme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.white.opacity(0.04))
        )
        .help(disabledReason ?? "")
    }

    private func present(_ action: EditAction) {
        switch action {
        case .upscale: break // handled via menu
        case .edit:
            editor.pendingEditSource = asset
            editor.pendingEditReplacementClipId = (shouldReplace ? clipId : nil)
            editor.pendingEditTrimmedSource = trimmedSourceIfEnabled()
            editor.showGenerationPanel = true
        case .rerun:
            do {
                markReplacementPendingIfNeeded()
                _ = try EditSubmitter.rerun(
                    asset: asset, editor: editor, service: service,
                    onComplete: replacementCompletion(),
                    onFailure: replacementFailure()
                )
            } catch {
                unmarkReplacementPendingIfNeeded()
                rerunError = error.localizedDescription
            }
        }
    }

    private func runUpscale(_ model: UpscaleModelConfig) {
        markReplacementPendingIfNeeded()
        let trim = trimmedSourceIfEnabled()
        _ = EditSubmitter.submitUpscale(
            asset: asset, model: model, editor: editor, service: service,
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
        return { [weak editor] newAsset in
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

    @ViewBuilder
    private func rerunParameters(_ gen: GenerationInput) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            rerunRow("cpu", label: "Model", value: ModelRegistry.displayName(for: gen.model))
            if gen.duration > 0 {
                rerunRow("clock", label: "Duration", value: "\(gen.duration)s")
            }
            if !gen.aspectRatio.isEmpty {
                rerunRow("aspectratio", label: "Aspect", value: gen.aspectRatio)
            }
            if let r = gen.resolution {
                rerunRow("rectangle.split.3x3", label: "Resolution", value: r)
            }
            let refCount = gen.imageURLs?.count ?? 0
            if refCount > 0 {
                rerunRow("photo.on.rectangle", label: "References", value: "\(refCount)")
            }
            if !gen.prompt.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Prompt")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                    Text(gen.prompt)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 2)
            }
        }
    }

    private func rerunRow(_ icon: String, label: String, value: String) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .frame(width: 14)
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Spacer()
            Text(value)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

}
