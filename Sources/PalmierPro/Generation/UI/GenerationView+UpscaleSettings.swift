import SwiftUI

private struct UpscaleOptionGroup: Identifiable {
    let title: String?
    let description: String?
    var options: [UpscaleSelectOption]
    var id: String { title ?? "_ungrouped" }
}

extension GenerationView {
    var upscaleSettingsContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            ForEach(upscaleModel.selectSettings) { upscaleSelectPicker($0) }
            ForEach(upscaleModel.numericSettings) { upscaleNumericControl($0) }
            ForEach(upscaleModel.toggleSettings) { setting in
                Toggle(setting.label, isOn: upscaleToggleBinding(setting))
                    .controlSize(.small)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
    }

    private func upscaleSelectPicker(_ setting: UpscaleSelectSetting) -> some View {
        let options = availableUpscaleOptions(setting)
        return Group {
            if options.count <= 4 {
                settingsPicker(
                    setting.label,
                    selection: upscaleSelectionBinding(setting, options: options),
                    options: options
                ) { $0.label }
            } else {
                let selection = upscaleSelectionBinding(setting, options: options)
                let selected = selection.wrappedValue
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(setting.label)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Menu {
                        ForEach(upscaleOptionGroups(options)) { group in
                            if let title = group.title {
                                Section(group.description.map { "\(title): \($0)" } ?? title) {
                                    upscaleOptionButtons(group.options, selection: selection, selected: selected)
                                }
                            } else {
                                upscaleOptionButtons(group.options, selection: selection, selected: selected)
                            }
                        }
                    } label: {
                        EditorMenuValue(text: selected.label, expanded: true)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    if let description = selected.description {
                        Text(description)
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func upscaleOptionGroups(_ options: [UpscaleSelectOption]) -> [UpscaleOptionGroup] {
        options.reduce(into: []) { groups, option in
            if let index = groups.firstIndex(where: { $0.title == option.group }) {
                groups[index].options.append(option)
            } else {
                groups.append(UpscaleOptionGroup(
                    title: option.group,
                    description: option.groupDescription,
                    options: [option]
                ))
            }
        }
    }

    @ViewBuilder
    private func upscaleOptionButtons(
        _ options: [UpscaleSelectOption],
        selection: Binding<UpscaleSelectOption>,
        selected: UpscaleSelectOption
    ) -> some View {
        ForEach(options, id: \.self) { option in
            Button {
                selection.wrappedValue = option
            } label: {
                if option == selected {
                    Label(upscaleOptionMenuTitle(option), systemImage: "checkmark")
                } else {
                    Text(upscaleOptionMenuTitle(option))
                }
            }
        }
    }

    private func upscaleOptionMenuTitle(_ option: UpscaleSelectOption) -> String {
        option.description.map { "\(option.label): \($0)" } ?? option.label
    }

    func availableUpscaleOptions(_ setting: UpscaleSelectSetting) -> [UpscaleSelectOption] {
        upscaleModel.availableOptions(for: setting, source: upscaleSource)
    }

    private func upscaleSelectionBinding(
        _ setting: UpscaleSelectSetting,
        options: [UpscaleSelectOption]
    ) -> Binding<UpscaleSelectOption> {
        Binding(
            get: {
                let value = upscaleSettings.selections[setting.id] ?? setting.defaultValue
                return options.first(where: { $0.value == value }) ?? options.first ?? setting.options[0]
            },
            set: { upscaleSettings.selections[setting.id] = $0.value }
        )
    }

    private func upscaleToggleBinding(_ setting: UpscaleToggleSetting) -> Binding<Bool> {
        Binding(
            get: { upscaleSettings.toggles[setting.id] ?? setting.defaultValue },
            set: { upscaleSettings.toggles[setting.id] = $0 }
        )
    }

    private func upscaleNumericControl(_ setting: UpscaleNumericSetting) -> some View {
        let storedValue = upscaleSettings.numbers[setting.id]
        let range = setting.minimum...setting.maximum
        let setValue: (Double) -> Void = {
            upscaleSettings.numbers[setting.id] = snappedUpscaleValue($0, setting: setting)
        }
        return HStack(spacing: AppTheme.Spacing.sm) {
            Text(setting.label)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Spacer(minLength: AppTheme.Spacing.sm)
            ScrubbableNumberField(
                value: storedValue ?? setting.minimum,
                range: range,
                format: upscaleNumericFormat(step: setting.step),
                dragSensitivity: setting.step,
                fieldWidth: AppTheme.EditorPanel.numericFieldWidth,
                dragValueAdjustment: { snappedUpscaleValue($0, setting: setting) },
                onChanged: setValue
            ) { setValue($0) }
            EditorResetButton(title: setting.label) {
                upscaleSettings.numbers.removeValue(forKey: setting.id)
            }
        }
    }

    private func snappedUpscaleValue(_ value: Double, setting: UpscaleNumericSetting) -> Double {
        let clamped = min(max(value, setting.minimum), setting.maximum)
        guard setting.step > 0 else { return clamped }
        let steps = ((clamped - setting.minimum) / setting.step).rounded()
        return min(max(setting.minimum + steps * setting.step, setting.minimum), setting.maximum)
    }

    private func upscaleNumericFormat(step: Double) -> String {
        if step >= 1 { return "%.0f" }
        if step >= 0.1 { return "%.1f" }
        return "%.2f"
    }

}
