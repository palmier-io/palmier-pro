import SwiftUI

/// "Remove Background" button + baked Invert/Feather controls. Progress/error state lives on
/// `editor.personMaskJobs`, not local `@State`, so it survives this panel being unmounted mid-bake.
struct PersonMaskPanel: View {
    @Environment(EditorViewModel.self) var editor
    let clip: Clip

    private var maskCachePath: String? { editor.personMaskCachePath(for: clip) }
    private var job: EditorViewModel.PersonMaskJob? { editor.personMaskJobs[clip.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            if let error = job?.error {
                Text(error)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if editor.isRemovingBackground(clipId: clip.id) {
                removingProgress
            } else if maskCachePath != nil {
                bakedControls
            } else {
                removeBackgroundButton
            }
        }
    }

    // MARK: - Not applied yet

    private var removeBackgroundButton: some View {
        Button(action: removeBackground) {
            Text("Remove Background")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Background.baseColor)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppTheme.Spacing.smMd)
                .background(RoundedRectangle(cornerRadius: AppTheme.Radius.sm).fill(AppTheme.Accent.primary))
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    // MARK: - Working

    private var removingProgress: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Removing background…")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            ProgressView(value: job?.progress ?? 0)
                .progressViewStyle(.linear)
            Text("\(Int((job?.progress ?? 0) * 100))%")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
    }

    // MARK: - Baked

    private var bakedControls: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            invertRow
            featherRow
            Button("Remove Mask") {
                editor.clearPersonMask(clipId: clip.id)
            }
            .buttonStyle(.plain)
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.secondaryColor)
        }
    }

    private var invertRow: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("Invert")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.Slider.labelColumn, alignment: .leading)
            Toggle("", isOn: Binding(
                get: { paramValue("invert") >= 0.5 },
                set: { setParam("invert", value: $0 ? 1 : 0, commit: true) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.strong))
            .labelsHidden()
            Spacer(minLength: 0)
        }
        .frame(height: KeyframesMetrics.rowHeight)
    }

    private var featherRow: some View {
        let spec = EffectRegistry.descriptor(id: "key.personMask")?.params.first { $0.key == "feather" }
        let range = spec?.range ?? 0...1
        let value = paramValue("feather")
        return HStack(spacing: AppTheme.Spacing.sm) {
            Text("Feather")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .frame(width: AppTheme.Slider.labelColumn, alignment: .leading)
            AdjustSlider(
                value: value, range: range, defaultValue: spec?.defaultValue ?? 0,
                onChanged: { setParam("feather", value: $0, commit: false) },
                onCommit: { setParam("feather", value: $0, commit: true) }
            )
            ScrubbableNumberField(
                value: value, range: range, displayMultiplier: 100, format: "%.0f",
                valueSuffix: "%", dragSensitivity: 0.5, fieldWidth: 50,
                onChanged: { setParam("feather", value: $0 / 100, commit: false) }
            ) { setParam("feather", value: $0 / 100, commit: true) }
        }
        .frame(height: KeyframesMetrics.rowHeight)
    }

    private func paramValue(_ key: String) -> Double {
        let spec = EffectRegistry.descriptor(id: "key.personMask")?.params.first { $0.key == key }
        let fallback = spec?.defaultValue ?? 0
        return (clip.effects ?? []).first { $0.type == "key.personMask" }?.params[key]?.resolved(at: 0, default: fallback) ?? fallback
    }

    private func setParam(_ key: String, value: Double, commit: Bool) {
        let mutate: (inout Clip) -> Void = { c in
            var effects = c.effects ?? []
            guard let i = effects.firstIndex(where: { $0.type == "key.personMask" }) else { return }
            effects[i].params[key] = EffectParam(value: value)
            c.effects = effects
        }
        if commit {
            editor.commitClipProperty(clipId: clip.id, mutate)
        } else {
            editor.applyClipProperty(clipId: clip.id, mutate)
        }
    }

    // MARK: - Actions

    private func removeBackground() {
        editor.removeBackground(clipId: clip.id)
    }
}
