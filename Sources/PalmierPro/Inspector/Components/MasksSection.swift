import SwiftUI

extension InspectorView {
    @ViewBuilder
    func masksSection(clips: [Clip]) -> some View {
        if clips.count == 1, let clip = clips.first, clip.mediaType == .video {
            EditorPanelGroup(L10n.string("Mask"), contentSpacing: AppTheme.Spacing.smMd) {
                ForEach(clip.masks ?? []) { mask in
                    maskRow(clip: clip, mask: mask)
                }
                if clip.masks?.isEmpty != false {
                    MaskPromptField(clipId: clip.id)
                }
            }
        }
    }

    @ViewBuilder
    private func maskRow(clip: Clip, mask: ObjectMask) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Toggle(isOn: Binding(
                    get: { mask.enabled },
                    set: { editor.setMaskEnabled(clipId: clip.id, maskId: mask.id, enabled: $0) }
                )) {
                    Text(verbatim: maskLabel(mask))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .lineLimit(1)
                }
                .toggleStyle(.checkbox)
                .disabled(mask.track == nil)

                Spacer()

                maskStatus(clip: clip, mask: mask)

                Button {
                    editor.removeObjectMask(clipId: clip.id, maskId: mask.id)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .buttonStyle(.plain)
                .help(L10n.string("Remove mask"))
            }

            if mask.track != nil {
                maskControls(clip: clip, mask: mask)
            }
        }
    }

    @ViewBuilder
    private func maskStatus(clip: Clip, mask: ObjectMask) -> some View {
        switch editor.maskTrackingStatus[mask.id] {
        case .running:
            ProgressView()
                .controlSize(.small)
                .help(L10n.string("Tracking object…"))
        case .failed(let message):
            Button {
                editor.retryMaskTracking(clipId: clip.id, maskId: mask.id)
            } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "exclamationmark.triangle")
                    Text(L10n.string("Retry"))
                }
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Status.errorColor)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: message))
        case nil:
            if mask.track == nil {
                Text(L10n.string("Not tracked"))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
    }

    @ViewBuilder
    private func maskControls(clip: Clip, mask: ObjectMask) -> some View {
        propertyRow(label: L10n.string("Remove Background")) {
            Toggle(String(), isOn: Binding(
                get: { mask.removesBackground },
                set: {
                    editor.setMaskRemovesBackground(
                        clipId: clip.id,
                        maskId: mask.id,
                        enabled: $0
                    )
                }
            ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(L10n.string("Remove Background"))
        }
        propertyRow(label: L10n.string("Invert")) {
            Toggle(String(), isOn: Binding(
                get: { mask.inverted },
                set: { editor.setMaskInverted(clipId: clip.id, maskId: mask.id, inverted: $0) }
            ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(L10n.string("Invert"))
        }
        propertyRow(label: L10n.string("Feather")) {
            ScrubbableNumberField(
                value: mask.feather,
                range: 0...100,
                format: "%.0f",
                dragSensitivity: 0.5,
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { newValue in
                    editor.previewMaskAdjustment(clipId: clip.id, maskId: mask.id) { $0.feather = newValue }
                }
            ) { newValue in
                editor.commitMaskAdjustment(clipId: clip.id, maskId: mask.id) { $0.feather = newValue }
            }
        }
        propertyRow(label: L10n.string("Expand")) {
            ScrubbableNumberField(
                value: mask.expansion,
                range: -50...50,
                format: "%.0f",
                dragSensitivity: 0.5,
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { newValue in
                    editor.previewMaskAdjustment(clipId: clip.id, maskId: mask.id) {
                        $0.expansion = newValue
                    }
                }
            ) { newValue in
                editor.commitMaskAdjustment(clipId: clip.id, maskId: mask.id) {
                    $0.expansion = newValue
                }
            }
        }
    }

    private func maskLabel(_ mask: ObjectMask) -> String {
        switch mask.seed {
        case .text(let prompt): prompt
        case .point: L10n.string("Point selection")
        }
    }
}

private struct MaskPromptField: View {
    @Environment(EditorViewModel.self) private var editor
    let clipId: String
    @State private var prompt = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.sm) {
                TextField(L10n.string("Describe what to mask"), text: $prompt)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .onSubmit(add)
                Button(L10n.string("Add Mask"), action: add)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .disabled(prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button(
                editor.maskPointSelectionClipId == clipId
                    ? L10n.string("Cancel Selection")
                    : L10n.string("Select in Viewer")
            ) {
                editor.beginMaskPointSelection(clipId: clipId)
            }
            .font(.system(size: AppTheme.FontSize.xs))
            if let errorMessage {
                Text(verbatim: errorMessage)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
    }

    private func add() {
        do {
            try editor.addObjectMask(clipId: clipId, prompt: prompt)
            prompt = ""
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
