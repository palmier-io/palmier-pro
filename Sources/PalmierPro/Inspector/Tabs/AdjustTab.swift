import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension InspectorView {

    // MARK: - Effects Tab

    struct EffectControl: Hashable {
        let effectId: String
        let paramKey: String
        var label: String? = nil
        var gradient: [Color]? = nil
    }

    /// Basic › Tone.
    private var toneControls: [EffectControl] {
        [
            EffectControl(effectId: "color.exposure", paramKey: "ev"),
            EffectControl(effectId: "color.contrast", paramKey: "amount"),
            EffectControl(effectId: "color.highlightsShadows", paramKey: "highlights"),
            EffectControl(effectId: "color.highlightsShadows", paramKey: "shadows"),
            EffectControl(effectId: "color.blacksWhites", paramKey: "blacks"),
            EffectControl(effectId: "color.blacksWhites", paramKey: "whites"),
        ]
    }

    /// Basic › White Balance.
    private var whiteBalanceControls: [EffectControl] {
        [
            EffectControl(effectId: "color.temperature", paramKey: "temperature", gradient: AppTheme.Slider.tempGradient),
            EffectControl(effectId: "color.temperature", paramKey: "tint", gradient: AppTheme.Slider.tintGradient),
        ]
    }

    /// Basic › Presence.
    private var presenceControls: [EffectControl] {
        [
            EffectControl(effectId: "color.vibrance", paramKey: "amount"),
            EffectControl(effectId: "color.saturation", paramKey: "amount"),
        ]
    }

    private var blurControls: [EffectControl] {
        [EffectControl(effectId: "blur.gaussian", paramKey: "radius", label: "Blur")]
    }

    private var vignetteControls: [EffectControl] {
        [
            EffectControl(effectId: "stylize.vignette", paramKey: "amount", label: "Amount"),
            EffectControl(effectId: "stylize.vignette", paramKey: "midpoint", label: "Midpoint"),
            EffectControl(effectId: "stylize.vignette", paramKey: "roundness", label: "Roundness"),
            EffectControl(effectId: "stylize.vignette", paramKey: "feather", label: "Feather"),
        ]
    }

    /// Motion blur groups its distance + direction rows under one section.
    private var motionBlurControls: [EffectControl] {
        [
            EffectControl(effectId: "blur.motion", paramKey: "radius", label: "Amount"),
            EffectControl(effectId: "blur.motion", paramKey: "angle", label: "Angle"),
        ]
    }

    private var glowControls: [EffectControl] {
        [
            EffectControl(effectId: "stylize.glow", paramKey: "intensity", label: "Intensity"),
            EffectControl(effectId: "stylize.glow", paramKey: "radius", label: "Radius"),
            EffectControl(effectId: "stylize.glow", paramKey: "threshold", label: "Threshold"),
            EffectControl(effectId: "stylize.glow", paramKey: "warmth", label: "Warmth"),
        ]
    }

    private var chromaKeyControls: [EffectControl] {
        [
            EffectControl(effectId: "key.chroma", paramKey: "tolerance", label: "Range"),
            EffectControl(effectId: "key.chroma", paramKey: "spill", label: "Spill"),
        ]
    }

    private var grainControls: [EffectControl] {
        [
            EffectControl(effectId: "stylize.grain", paramKey: "amount", label: "Amount"),
            EffectControl(effectId: "stylize.grain", paramKey: "size", label: "Size"),
        ]
    }

    private var detailControls: [EffectControl] {
        [
            EffectControl(effectId: "blur.sharpen", paramKey: "amount", label: "Sharpen"),
            EffectControl(effectId: "blur.noiseReduction", paramKey: "amount", label: "Noise Reduction"),
            EffectControl(effectId: "detail.clarity", paramKey: "clarity", label: "Clarity"),
            EffectControl(effectId: "detail.clarity", paramKey: "dehaze", label: "Dehaze"),
        ]
    }

    private var basicEffectIds: Set<String> {
        Set((toneControls + whiteBalanceControls + presenceControls).map(\.effectId))
    }

    private var effectsEffectIds: Set<String> {
        Set((detailControls + blurControls + motionBlurControls + vignetteControls + grainControls + glowControls + chromaKeyControls).map(\.effectId))
    }

    @ViewBuilder
    func effectsTabContent() -> some View {
        let clips = nonTextVisualClips
        VStack(alignment: .leading, spacing: 0) {
            adjustSection(title: "Basic Correction", effectIds: basicEffectIds, clips: clips) {
                adjustSubgroup(title: "Tone", controls: toneControls, clips: clips)
                adjustSubgroup(title: "White Balance", controls: whiteBalanceControls, clips: clips)
                adjustSubgroup(title: "Presence", controls: presenceControls, clips: clips)
            }
            adjustSection(title: "Curves", effectIds: ["color.curves"], clips: clips) {
                curvesContent(clips: clips)
            }
            adjustSection(title: "Color Wheels", effectIds: ["color.wheels"], clips: clips) {
                wheelsContent(clips: clips)
            }
            adjustSection(title: "Hue Curves", effectIds: ["color.hueCurves"], clips: clips) {
                hueCurvesContent(clips: clips)
            }
            adjustSection(title: "LUTs", effectIds: ["color.lut"], clips: clips) {
                lutContent(clips: clips)
            }
            adjustSection(title: "Effects", effectIds: effectsEffectIds, clips: clips) {
                adjustSubgroup(title: "Detail", controls: detailControls, clips: clips)
                adjustSubgroup(title: "Blur", controls: blurControls, clips: clips)
                adjustSubgroup(title: "Motion Blur", controls: motionBlurControls, clips: clips)
                adjustSubgroup(title: "Vignette", controls: vignetteControls, clips: clips)
                adjustSubgroup(title: "Film Grain", controls: grainControls, clips: clips)
                adjustSubgroup(title: "Glow", controls: glowControls, clips: clips)
                adjustSubgroup(title: "Chroma Key", controls: chromaKeyControls, clips: clips)
            }
        }
    }

    // MARK: Section chrome

    @ViewBuilder
    private func adjustSection<Content: View>(
        title: String,
        effectIds: Set<String>,
        clips: [Clip],
        @ViewBuilder content: () -> Content
    ) -> some View {
        let expanded = !collapsedAdjustSections.contains(title)
        let hasEffects = anyAdjusted(effectIds, clips: clips)
        let isOn = !hasEffects || sectionEnabled(effectIds, clips: clips)
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.IconSize.xxs, alignment: .center)
                sectionTitleLabel(title: title)
                Spacer(minLength: AppTheme.Spacing.sm)
                if hasEffects {
                    EditorResetButton(
                        title: title,
                        action: { resetEffects(effectIds, clips: clips, actionName: "Reset \(title)") }
                    )
                }
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { setSectionEnabled(effectIds, clips: clips, enabled: $0) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!hasEffects)
                .help(hasEffects ? "Enable \(title.lowercased())" : "No adjustments yet")
                .accessibilityLabel("Enable \(title)")
            }
            .padding(.horizontal, AppTheme.Spacing.lg)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.Background.surfaceColor)
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded { collapsedAdjustSections.insert(title) }
                else { collapsedAdjustSections.remove(title) }
            }
            if expanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    content()
                }
                .padding(.horizontal, AppTheme.Spacing.lg)
                .padding(.vertical, AppTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .overlay(alignment: .bottom) { sectionDivider }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(AppTheme.Border.primaryColor)
            .frame(height: AppTheme.BorderWidth.thin)
    }

    @ViewBuilder
    private func adjustSubgroup(title: String, controls: [EffectControl], clips: [Clip]) -> some View {
        let expanded = !collapsedAdjustSubgroups.contains(title)
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.IconSize.xxs, alignment: .center)
                sectionTitleLabel(title: title)
                Spacer(minLength: 0)
                if title == "Chroma Key", clips.count == 1, let clip = clips.first {
                    let sampling = editor.chromaKeySamplingClipId == clip.id
                    Button { editor.toggleChromaKeySampling(clipId: clip.id) } label: {
                        Image(systemName: "eyedropper")
                            .foregroundStyle(sampling ? AppTheme.Accent.primary : AppTheme.Text.secondaryColor)
                    }
                    .buttonStyle(.plain)
                    .disabled(editor.activePreviewTab != .timeline)
                    .help(sampling ? "Cancel key color sampling" : "Sample key color")
                    .accessibilityLabel(sampling ? "Cancel Key Color Sampling" : "Sample Key Color")
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if expanded { collapsedAdjustSubgroups.insert(title) }
                else { collapsedAdjustSubgroups.remove(title) }
            }
            if expanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    ForEach(controls, id: \.self) { control in
                        adjustmentRow(control, clips: clips)
                    }
                }
            }
        }
    }

    // MARK: Curves

    @ViewBuilder
    private func curvesContent(clips: [Clip]) -> some View {
        CurveEditorView(
            curve: curve(in: clips.first?.effects ?? []),
            onChange: { setCurveChannel($0, points: $1, clips: clips, commit: false, action: "Edit Curves") },
            onCommit: { setCurveChannel($0, points: $1, clips: clips, commit: true, action: "Edit Curves") }
        )
    }

    private func curve(in effects: [Effect]) -> GradeCurve {
        guard let json = effects.first(where: { $0.type == "color.curves" })?
            .params["curve"]?.string else { return GradeCurve() }
        return GradeCurve(json: json) ?? GradeCurve()
    }

    private func setCurveChannel(
        _ channel: CurveEditorView.Channel,
        points: [CurvePoint],
        clips: [Clip],
        commit: Bool,
        action: String
    ) {
        let mutate: (inout [Effect]) -> Void = { [self] effects in
            var curve = curve(in: effects)
            switch channel {
            case .master: curve.master = points
            case .red: curve.red = points
            case .green: curve.green = points
            case .blue: curve.blue = points
            }
            upsertCurve(curve, in: &effects)
        }
        if commit {
            commitEffects(clips, actionName: action, mutate)
        } else {
            applyEffects(clips, mutate)
        }
    }

    private func upsertCurve(_ curve: GradeCurve, in effects: inout [Effect]) {
        let existing = effects.firstIndex { $0.type == "color.curves" }
        guard !curve.isIdentity, let json = curve.encoded() else {
            if let existing { effects.remove(at: existing) }
            return
        }
        if let existing {
            effects[existing].params["curve"] = EffectParam(string: json)
        } else {
            var effect = Effect(type: "color.curves")
            effect.params["curve"] = EffectParam(string: json)
            effects.insert(effect, at: alwaysOnInsertIndex(effects, for: "color.curves"))
        }
    }

    // MARK: Hue curves

    @ViewBuilder
    private func hueCurvesContent(clips: [Clip]) -> some View {
        HueCurveEditorView(
            curves: HueCurves.read(from: clips.first?.effects ?? []),
            onChange: { setHueCurveChannel($0, points: $1, clips: clips, commit: false, action: "Edit Hue Curves") },
            onCommit: { setHueCurveChannel($0, points: $1, clips: clips, commit: true, action: "Edit Hue Curves") }
        )
    }

    private func setHueCurveChannel(
        _ channel: HueCurves.Channel,
        points: [CurvePoint],
        clips: [Clip],
        commit: Bool,
        action: String
    ) {
        let mutate: (inout [Effect]) -> Void = { effects in
            var curves = HueCurves.read(from: effects)
            curves.set(channel, points)
            curves.upsert(into: &effects)
        }
        if commit {
            commitEffects(clips, actionName: action, mutate)
        } else {
            applyEffects(clips, mutate)
        }
    }

    // MARK: Color wheels

    @ViewBuilder
    private func wheelsContent(clips: [Clip]) -> some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            wheelControl("Lift", prefix: "lift", clips: clips)
            wheelControl("Gamma", prefix: "gamma", clips: clips)
            wheelControl("Gain", prefix: "gain", clips: clips)
        }
        .frame(maxWidth: .infinity)
    }

    private func wheelControl(_ title: String, prefix: String, clips: [Clip]) -> some View {
        let mKey = "\(prefix)_m"
        let mSpec = EffectRegistry.descriptor(id: "color.wheels")?.params.first { $0.key == mKey }
        let mDefault = mSpec?.defaultValue ?? 0
        let mRange = mSpec?.range ?? 0...2
        return ColorWheelControl(
            title: title,
            x: sharedClipValue(clips) { wheelParam($0, "\(prefix)_x", default: 0) } ?? 0,
            y: sharedClipValue(clips) { wheelParam($0, "\(prefix)_y", default: 0) } ?? 0,
            master: sharedClipValue(clips) { wheelParam($0, mKey, default: mDefault) } ?? mDefault,
            masterRange: mRange,
            masterDefault: mDefault,
            onColorChanged: { setWheelColor(prefix, $0, $1, clips: clips, commit: false) },
            onColorCommit: { setWheelColor(prefix, $0, $1, clips: clips, commit: true) },
            onMasterChanged: { setControlParam(EffectControl(effectId: "color.wheels", paramKey: mKey), label: title, value: $0, clips: clips, commit: false) },
            onMasterCommit: { setControlParam(EffectControl(effectId: "color.wheels", paramKey: mKey), label: title, value: $0, clips: clips, commit: true) }
        )
    }

    private func wheelParam(_ clip: Clip, _ key: String, default def: Double) -> Double {
        (clip.effects ?? []).first { $0.type == "color.wheels" }?.params[key]?.resolved(at: 0, default: def) ?? def
    }

    /// Both pad axes upserted in one mutation so a drag is a single undo entry.
    private func setWheelColor(_ prefix: String, _ x: Double, _ y: Double, clips: [Clip], commit: Bool) {
        let xc = EffectControl(effectId: "color.wheels", paramKey: "\(prefix)_x")
        let yc = EffectControl(effectId: "color.wheels", paramKey: "\(prefix)_y")
        let mutate: (inout [Effect]) -> Void = { [self] effects in
            upsertControl(&effects, control: xc, value: x)
            upsertControl(&effects, control: yc, value: y)
        }
        if commit {
            commitEffects(clips, actionName: "Adjust \(prefix.capitalized)", mutate)
        } else {
            applyEffects(clips, mutate)
        }
    }

    // MARK: LUT

    @ViewBuilder
    private func lutContent(clips: [Clip]) -> some View {
        let path = lutPath(in: clips)
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            lutFileRow(path: path, clips: clips)
            if path != nil { lutIntensityRow(clips: clips) }
        }
    }

    private func lutFileRow(path: String?, clips: [Clip]) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("File")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.Slider.labelColumn, alignment: .leading)
            Button { chooseLUT(clips: clips) } label: {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(path.map { ($0 as NSString).lastPathComponent } ?? "Choose…")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(path == nil ? AppTheme.Text.tertiaryColor : AppTheme.Text.primaryColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AppTheme.Spacing.smMd)
                .padding(.vertical, AppTheme.Spacing.xs)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.white.opacity(AppTheme.Opacity.hint))
                )
            }
            .buttonStyle(.plain)
            .help(path ?? "Choose a .cube LUT file")
        }
        .frame(height: KeyframesMetrics.rowHeight)
    }

    private func lutIntensityRow(clips: [Clip]) -> some View {
        let spec = EffectRegistry.descriptor(id: "color.lut")?.params.first { $0.key == "intensity" }
        let range = spec?.range ?? 0...1
        let value = lutIntensity(in: clips)
        return HStack(spacing: AppTheme.Spacing.sm) {
            Text("Intensity")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
                .frame(width: AppTheme.Slider.labelColumn, alignment: .leading)
            AdjustSlider(
                value: value, range: range, defaultValue: spec?.defaultValue ?? 1,
                onChanged: { setLUTIntensity($0, clips: clips, commit: false) },
                onCommit: { setLUTIntensity($0, clips: clips, commit: true) }
            )
            ScrubbableNumberField(
                value: value, range: range, displayMultiplier: 100, format: "%.0f",
                valueSuffix: "%", dragSensitivity: 0.5, fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                onChanged: { setLUTIntensity($0 / 100, clips: clips, commit: false) }
            ) { setLUTIntensity($0 / 100, clips: clips, commit: true) }
        }
        .frame(height: KeyframesMetrics.rowHeight)
    }

    private func lutPath(in clips: [Clip]) -> String? {
        (clips.first?.effects ?? []).first { $0.type == "color.lut" }?.params["path"]?.string
    }

    private func lutIntensity(in clips: [Clip]) -> Double {
        (clips.first?.effects ?? []).first { $0.type == "color.lut" }?
            .params["intensity"]?.resolved(at: 0, default: 1) ?? 1
    }

    private func chooseLUT(clips: [Clip]) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .cube LUT file"
        if let cube = UTType(filenameExtension: "cube") { panel.allowedContentTypes = [cube] }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            setLUTPath(url.path, clips: clips)
        }
    }

    private func setLUTPath(_ path: String, clips: [Clip]) {
        // Copy into project storage so the LUT survives saves/moves (project packages drop unknown files).
        guard let stored = try? LUTLoader.store(path: path, projectId: editor.projectId) else { return }
        commitEffects(clips, actionName: "Apply LUT") { effects in
            if let i = effects.firstIndex(where: { $0.type == "color.lut" }) {
                effects[i].params["path"] = EffectParam(string: stored)
            } else {
                var effect = Effect(type: "color.lut")
                effect.params["path"] = EffectParam(string: stored)
                effects.insert(effect, at: alwaysOnInsertIndex(effects, for: "color.lut"))
            }
        }
    }

    private func setLUTIntensity(_ value: Double, clips: [Clip], commit: Bool) {
        let mutate: (inout [Effect]) -> Void = { effects in
            guard let i = effects.firstIndex(where: { $0.type == "color.lut" }) else { return }
            effects[i].params["intensity"] = EffectParam(value: value)
        }
        if commit {
            commitEffects(clips, actionName: "Change LUT Intensity", mutate)
        } else {
            applyEffects(clips, mutate)
        }
    }

    // MARK: Adjustment rows

    @ViewBuilder
    private func adjustmentRow(_ control: EffectControl, clips: [Clip]) -> some View {
        if let descriptor = EffectRegistry.descriptor(id: control.effectId),
           let spec = descriptor.params.first(where: { $0.key == control.paramKey }) {
            let label = control.label ?? spec.label
            HStack(spacing: AppTheme.Spacing.sm) {
                Text(label)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
                    .frame(width: AppTheme.Slider.labelColumn, alignment: .leading)
                AdjustSlider(
                    value: sharedClipValue(clips) { controlValue($0, control, spec) } ?? spec.defaultValue,
                    range: spec.range,
                    gradient: control.gradient,
                    defaultValue: spec.defaultValue,
                    onChanged: { setControlParam(control, label: label, value: $0, clips: clips, commit: false) },
                    onCommit: { setControlParam(control, label: label, value: $0, clips: clips, commit: true) }
                )
                ScrubbableNumberField(
                    value: sharedClipValue(clips) { controlValue($0, control, spec) },
                    range: spec.range,
                    format: effectParamFormat(spec),
                    valueSuffix: spec.unit.isEmpty ? "" : " \(spec.unit)",
                    dragSensitivity: effectParamSensitivity(spec),
                    fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                    onChanged: { setControlParam(control, label: label, value: $0, clips: clips, commit: false) }
                ) { setControlParam(control, label: label, value: $0, clips: clips, commit: true) }
            }
            .frame(height: KeyframesMetrics.rowHeight)
        }
    }

    private func controlValue(_ clip: Clip, _ control: EffectControl, _ spec: EffectParamSpec) -> Double {
        (clip.effects ?? []).first { $0.type == control.effectId }?
            .params[control.paramKey]?.resolved(at: 0, default: spec.defaultValue) ?? spec.defaultValue
    }

    private func setControlParam(
        _ control: EffectControl, label: String, value: Double, clips: [Clip], commit: Bool
    ) {
        let mutate: (inout [Effect]) -> Void = { [self] effects in
            upsertControl(&effects, control: control, value: value)
        }
        if commit {
            commitEffects(clips, actionName: "Change \(label)", mutate)
        } else {
            applyEffects(clips, mutate)
        }
    }

    /// Upsert one param into the singleton effect of its type, inserting in canonical
    /// order when first touched and pruning it when every param returns to default
    /// (so a neutral adjustment carries no effect / no render pass).
    private func upsertControl(_ effects: inout [Effect], control: EffectControl, value: Double) {
        guard let descriptor = EffectRegistry.descriptor(id: control.effectId) else { return }
        if let i = effects.firstIndex(where: { $0.type == control.effectId }) {
            effects[i].params[control.paramKey] = EffectParam(value: value)
            let allDefault = descriptor.params.allSatisfy { spec in
                (effects[i].params[spec.key]?.value ?? spec.defaultValue) == spec.defaultValue
            }
            if allDefault { effects.remove(at: i) }
        } else {
            let paramDefault = descriptor.params.first { $0.key == control.paramKey }?.defaultValue
            guard value != paramDefault else { return }
            var effect = descriptor.makeEffect()
            effect.params[control.paramKey] = EffectParam(value: value)
            effects.insert(effect, at: alwaysOnInsertIndex(effects, for: control.effectId))
        }
    }

    private func alwaysOnInsertIndex(_ effects: [Effect], for effectId: String) -> Int {
        EffectRegistry.insertIndex(effects, for: effectId)
    }

    private func anyAdjusted(_ ids: Set<String>, clips: [Clip]) -> Bool {
        clips.contains { ($0.effects ?? []).contains { ids.contains($0.type) } }
    }

    private func resetEffects(_ ids: Set<String>, clips: [Clip], actionName: String) {
        commitEffects(clips, actionName: actionName) { effects in
            effects.removeAll { ids.contains($0.type) }
        }
    }

    private func sectionEnabled(_ ids: Set<String>, clips: [Clip]) -> Bool {
        !clips.contains { ($0.effects ?? []).contains { ids.contains($0.type) && !$0.enabled } }
    }

    private func setSectionEnabled(_ ids: Set<String>, clips: [Clip], enabled: Bool) {
        commitEffects(clips, actionName: enabled ? "Enable Section" : "Disable Section") { effects in
            for i in effects.indices where ids.contains(effects[i].type) {
                effects[i].enabled = enabled
            }
        }
    }

    private func effectParamFormat(_ spec: EffectParamSpec) -> String {
        (spec.range.upperBound - spec.range.lowerBound) <= 20 ? "%.2f" : "%.0f"
    }

    private func effectParamSensitivity(_ spec: EffectParamSpec) -> Double {
        max(0.01, (spec.range.upperBound - spec.range.lowerBound) / 200)
    }

    /// Live edit (no undo entry) — mirrors applyClipProperty's refresh-only path.
    private func applyEffects(_ clips: [Clip], _ mutate: @escaping (inout [Effect]) -> Void) {
        editor.applyClipProperties(clipIds: clips.map(\.id)) { c in
            var effects = c.effects ?? []
            mutate(&effects)
            c.effects = effects.isEmpty ? nil : effects
        }
    }

    /// One undoable entry across all selected clips.
    private func commitEffects(
        _ clips: [Clip], actionName: String, _ mutate: @escaping (inout [Effect]) -> Void
    ) {
        editor.commitClipProperties(clipIds: clips.map(\.id), actionName: actionName) { c in
            var effects = c.effects ?? []
            mutate(&effects)
            c.effects = effects.isEmpty ? nil : effects
        }
    }
}
