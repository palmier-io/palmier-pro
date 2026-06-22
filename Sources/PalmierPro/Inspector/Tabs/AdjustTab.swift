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

    /// Single-knob effects as always-on rows, labeled by effect name.
    private var stylizeControls: [EffectControl] {
        [
            EffectControl(effectId: "blur.gaussian", paramKey: "radius", label: "Blur"),
            EffectControl(effectId: "blur.sharpen", paramKey: "amount", label: "Sharpen"),
            EffectControl(effectId: "blur.noiseReduction", paramKey: "amount", label: "Noise Reduction"),
            EffectControl(effectId: "stylize.vignette", paramKey: "intensity", label: "Vignette"),
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
        ]
    }

    /// Canonical order the fixed adjustment sections insert their effects in.
    private var alwaysOnEffectOrder: [String] {
        ["color.exposure", "color.contrast", "color.highlightsShadows", "color.blacksWhites",
         "color.temperature", "color.vibrance", "color.saturation", "color.wheels", "color.curves",
         "color.lut", "blur.gaussian", "blur.sharpen", "blur.noiseReduction", "blur.motion",
         "stylize.vignette", "stylize.glow"]
    }

    @ViewBuilder
    func effectsTabContent() -> some View {
        let clips = nonTextVisualClips
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            capsuleTabBar(titles: AdjustTab.allCases.map(\.rawValue), selected: adjustSubTab.rawValue) { title in
                if let tab = AdjustTab(rawValue: title) { adjustSubTab = tab }
            }
            switch adjustSubTab {
            case .basic:
                adjustmentSection(title: "Tone", controls: toneControls, clips: clips)
                adjustmentSection(title: "White Balance", controls: whiteBalanceControls, clips: clips)
                adjustmentSection(title: "Presence", controls: presenceControls, clips: clips)
            case .color:
                curvesSection(clips: clips)
                wheelsSection(clips: clips)
                lutSection(clips: clips)
            case .effects:
                adjustmentSection(title: "Effects", controls: stylizeControls, clips: clips)
                adjustmentSection(title: "Motion Blur", controls: motionBlurControls, clips: clips)
                adjustmentSection(title: "Glow", controls: glowControls, clips: clips)
            }
        }
    }

    // MARK: Curves

    @ViewBuilder
    private func curvesSection(clips: [Clip]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.xs) {
                sectionTitleLabel(title: "Curves")
                Spacer()
                if anyAdjusted(["color.curves"], clips: clips) {
                    resetButton(
                        onReset: { setCurve(GradeCurve(), clips: clips, commit: true, action: "Reset Curves") },
                        help: "Reset curves"
                    )
                }
            }
            CurveEditorView(
                curve: curve(in: clips.first?.effects ?? []),
                onChange: { setCurveChannel($0, points: $1, clips: clips, commit: false, action: "Edit Curves") },
                onCommit: { setCurveChannel($0, points: $1, clips: clips, commit: true, action: "Edit Curves") }
            )
            .padding(.leading, sectionContentIndent)
        }
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

    /// Upsert the curves effect in place (stable id), pruning it when the curve is identity.
    private func setCurve(_ curve: GradeCurve, clips: [Clip], commit: Bool, action: String) {
        let mutate: (inout [Effect]) -> Void = { [self] effects in
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

    // MARK: Color wheels

    @ViewBuilder
    private func wheelsSection(clips: [Clip]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.xs) {
                sectionTitleLabel(title: "Color Wheels")
                Spacer()
                if anyAdjusted(["color.wheels"], clips: clips) {
                    HoldToPreviewButton(
                        onPress: { previewSection(["color.wheels"], clips: clips, enabled: false) },
                        onRelease: { previewSection(["color.wheels"], clips: clips, enabled: true) }
                    )
                    resetButton(
                        onReset: { resetEffects(["color.wheels"], clips: clips, actionName: "Reset Color Wheels") },
                        help: "Reset color wheels"
                    )
                }
            }
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                wheelControl("Lift", prefix: "lift", clips: clips)
                wheelControl("Gamma", prefix: "gamma", clips: clips)
                wheelControl("Gain", prefix: "gain", clips: clips)
            }
            .frame(maxWidth: .infinity)
            .padding(.leading, sectionContentIndent)
        }
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
    private func lutSection(clips: [Clip]) -> some View {
        let path = lutPath(in: clips)
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.xs) {
                sectionTitleLabel(title: "LUT")
                Spacer()
                if path != nil {
                    HoldToPreviewButton(
                        onPress: { previewSection(["color.lut"], clips: clips, enabled: false) },
                        onRelease: { previewSection(["color.lut"], clips: clips, enabled: true) }
                    )
                    resetButton(
                        onReset: { clearLUT(clips: clips) },
                        help: "Remove LUT"
                    )
                }
            }
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                lutFileRow(path: path, clips: clips)
                if path != nil { lutIntensityRow(clips: clips) }
            }
            .padding(.leading, sectionContentIndent)
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
                valueSuffix: "%", dragSensitivity: 0.5, fieldWidth: 50,
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
        commitEffects(clips, actionName: "Apply LUT") { effects in
            if let i = effects.firstIndex(where: { $0.type == "color.lut" }) {
                effects[i].params["path"] = EffectParam(string: path)
            } else {
                var effect = Effect(type: "color.lut")
                effect.params["path"] = EffectParam(string: path)
                effects.insert(effect, at: alwaysOnInsertIndex(effects, for: "color.lut"))
            }
        }
    }

    private func clearLUT(clips: [Clip]) {
        commitEffects(clips, actionName: "Remove LUT") { effects in
            effects.removeAll { $0.type == "color.lut" }
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

    // MARK: Always-on adjustment sections (Color, Effects)

    @ViewBuilder
    private func adjustmentSection(title: String, controls: [EffectControl], clips: [Clip]) -> some View {
        let ids = Set(controls.map(\.effectId))
        let expanded = !collapsedAdjustSections.contains(title)
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Button {
                    if expanded { collapsedAdjustSections.insert(title) }
                    else { collapsedAdjustSections.remove(title) }
                } label: {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        sectionTitleLabel(title: title)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                if anyAdjusted(ids, clips: clips) {
                    HoldToPreviewButton(
                        onPress: { previewSection(ids, clips: clips, enabled: false) },
                        onRelease: { previewSection(ids, clips: clips, enabled: true) }
                    )
                    resetButton(
                        onReset: { resetEffects(ids, clips: clips, actionName: "Reset \(title)") },
                        help: "Reset \(title.lowercased())"
                    )
                }
            }
            if expanded {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                    ForEach(controls, id: \.self) { control in
                        adjustmentRow(control, clips: clips)
                    }
                }
                .padding(.leading, sectionContentIndent)
            }
        }
    }

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
                    fieldWidth: 50,
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
        let rank = alwaysOnEffectOrder.firstIndex(of: effectId) ?? Int.max
        return effects.firstIndex { (alwaysOnEffectOrder.firstIndex(of: $0.type) ?? Int.max) > rank } ?? effects.count
    }

    private func anyAdjusted(_ ids: Set<String>, clips: [Clip]) -> Bool {
        clips.contains { ($0.effects ?? []).contains { ids.contains($0.type) } }
    }

    private func resetEffects(_ ids: Set<String>, clips: [Clip], actionName: String) {
        commitEffects(clips, actionName: actionName) { effects in
            effects.removeAll { ids.contains($0.type) }
        }
    }

    /// Live preview of a section toggled off/on. Both go through the cheap
    /// refresh-visuals path (no full composition rebuild), so the release doesn't flicker.
    private func previewSection(_ ids: Set<String>, clips: [Clip], enabled: Bool) {
        applyEffects(clips) { effects in
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
        editor.undoManager?.beginUndoGrouping()
        editor.commitClipProperties(clipIds: clips.map(\.id)) { c in
            var effects = c.effects ?? []
            mutate(&effects)
            c.effects = effects.isEmpty ? nil : effects
        }
        editor.undoManager?.endUndoGrouping()
        editor.undoManager?.setActionName(actionName)
    }
}
