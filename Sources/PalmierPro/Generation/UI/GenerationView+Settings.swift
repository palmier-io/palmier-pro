import SwiftUI

private enum GenerationSettingsLayout {
    static let popoverWidth: CGFloat = 220
    static let imagePopoverWidth: CGFloat = 270
    static let upscalePopoverWidth: CGFloat = 280
    static let upscalePopoverMaxHeight: CGFloat = 500
    static let imageAspectGridMinWidth: CGFloat = 78
    static let gridButtonMinHeight: CGFloat = 30
}

// Type tabs, model/voice pickers, and the settings popover.
extension GenerationView {

    // MARK: - Type picker

    var typeTabs: some View {
        HStack(spacing: 0) {
            ForEach(availableGenerationTypes, id: \.self) { type in
                Button {
                    withAnimation(.easeInOut(duration: AppTheme.Anim.hover)) { selectedType = type }
                } label: {
                    VStack(spacing: AppTheme.Spacing.xxs) {
                        Image(systemName: type.icon)
                            .font(.system(
                                size: AppTheme.FontSize.smMd,
                                weight: selectedType == type ? .semibold : .medium
                            ))
                            .foregroundStyle(selectedType == type ? type.accentColor : AppTheme.Text.tertiaryColor)
                        Text(L10n.string(key: type.title))
                            .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                            .foregroundStyle(selectedType == type ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                    }
                    .frame(width: AppTheme.GenerationPanel.typeTabWidth, height: AppTheme.IconSize.lgXl)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.concentric(
                            outer: AppTheme.Radius.sm,
                            padding: AppTheme.Spacing.xxs
                        ))
                            .fill(selectedType == type ? AppTheme.Interaction.fill(AppTheme.Opacity.faint) : .clear)
                    )
                    .hoverHighlight(cornerRadius: AppTheme.Radius.concentric(
                        outer: AppTheme.Radius.sm,
                        padding: AppTheme.Spacing.xxs
                    ))
                }
                .buttonStyle(.plain)
                .help(L10n.string(key: type.title))
                .accessibilityLabel(L10n.string(key: type.title))
            }
        }
        .padding(AppTheme.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Interaction.fill(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    // MARK: - Model picker

    var modelPicker: some View {
        Menu {
            switch selectedType {
            case .video:
                ForEach(enabledVideoModelsByProvider) { group in
                    Section {
                        ForEach(group.models, id: \.index) { item in
                            Button {
                                selectedVideoModelIndex = item.index
                            } label: {
                                modelMenuLabel(item.model.entry)
                            }
                        }
                    } header: {
                        modelFamilyHeader(group)
                    }
                }
            case .image:
                ForEach(enabledImageModels, id: \.index) { item in
                    Button {
                        selectedImageModelIndex = item.index
                    } label: {
                        modelMenuLabel(item.model.entry)
                    }
                }
            case .audio:
                ForEach(AudioModelConfig.Category.allCases, id: \.self) { category in
                    if let items = enabledAudioModelsByCategory[category], !items.isEmpty {
                        Section(category.localizedLabel) {
                            ForEach(items, id: \.index) { item in
                                Button {
                                    selectedAudioModelIndex = item.index
                                } label: {
                                    modelMenuLabel(item.model.entry)
                                }
                            }
                        }
                    }
                }
            case .upscale:
                ForEach([ClipType.image, .video], id: \.self) { type in
                    if let items = enabledUpscaleModelsByType[type], !items.isEmpty {
                        Section(type.localizedTrackLabel) {
                            ForEach(items, id: \.index) { item in
                                Button {
                                    selectedUpscaleModelIndex = item.index
                                } label: {
                                    modelMenuLabel(item.model.entry)
                                }
                            }
                        }
                    }
                }
            }
            Divider()
            Button {
                SettingsWindowController.shared.show(tab: .models)
            } label: {
                Label(L10n.string("Add models…"), systemImage: "plus")
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                if let iconKey = currentProviderIconKey {
                    ProviderLogo(iconKey: iconKey, size: AppTheme.IconSize.xs)
                }
                Text(currentModelName)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .hoverHighlight()
    }

    private var currentProviderIconKey: String? {
        switch selectedType {
        case .video: videoModel.entry.providerIconKey
        case .image: imageModel.entry.providerIconKey
        case .audio: audioModel.entry.providerIconKey
        case .upscale: upscaleModel.entry.providerIconKey
        }
    }

    @ViewBuilder
    private func modelMenuLabel(_ entry: CatalogEntry) -> some View {
        if let iconKey = entry.providerIconKey {
            Label {
                Text(entry.displayName)
            } icon: {
                ProviderLogo(iconKey: iconKey, size: AppTheme.IconSize.xs)
            }
        } else {
            Text(entry.displayName)
        }
    }

    @ViewBuilder
    private func modelFamilyHeader(_ group: VideoModelProviderGroup) -> some View {
        if let iconKey = group.providerIconKey {
            HStack(spacing: AppTheme.Spacing.xs) {
                ProviderLogo(iconKey: iconKey, size: AppTheme.IconSize.xs)
                Text(group.name)
            }
        } else {
            Text(group.name)
        }
    }

    var voicePicker: some View {
        Menu {
            if let voices = audioModel.voices {
                ForEach(voices, id: \.self) { voice in
                    Button(voice) { selectedVoice = voice }
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "person.wave.2")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(verbatim: selectedVoice.isEmpty ? (audioModel.defaultVoice ?? L10n.string("Voice")) : selectedVoice)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xs)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .hoverHighlight()
    }

    var languagePicker: some View {
        Menu {
            if let languages = audioModel.targetLanguages {
                ForEach(languages, id: \.self) { code in
                    Button(AudioModelConfig.languageName(code, locale: AppLocalization.shared.activeLocale)) {
                        selectedTargetLanguage = code
                    }
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "globe")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(AudioModelConfig.languageName(
                    selectedTargetLanguage,
                    locale: AppLocalization.shared.activeLocale
                ))
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.micro, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xs)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .hoverHighlight()
        .help(L10n.string("Target Language"))
    }

    // MARK: - Settings
    var settingsSummary: String {
        var parts: [String] = []
        if selectedType == .upscale {
            for id in ["targetResolution", "targetFPS"] {
                guard let setting = upscaleModel.selectSettings.first(where: { $0.id == id }) else { continue }
                let value = upscaleSettings.selections[id] ?? setting.defaultValue
                if id == "targetFPS", value == "source" {
                    parts.append(upscaleSourceFPSLabel)
                } else if let label = setting.options.first(where: { $0.value == value })?.label {
                    parts.append(label)
                }
            }
            return parts.isEmpty ? L10n.string("Settings") : parts.joined(separator: " \u{00B7} ")
        }
        if selectedType == .audio {
            if audioModel.hasDurationControl, !audioUsesSource {
                parts.append("\(selectedAudioDuration)s")
            }
            if audioModel.supportsInstrumental && instrumental { parts.append(L10n.string("Instrumental")) }
            if audioModel.supportsMultilingual && multilingual { parts.append(L10n.string("Multilingual")) }
            return parts.isEmpty ? L10n.string("Settings") : parts.joined(separator: " \u{00B7} ")
        }
        if currentResolutions != nil { parts.append(resolutionLabel(selectedResolution)) }
        if currentQualities != nil { parts.append(selectedQuality) }
        if selectedType == .video { parts.append("\(selectedDuration)s") }
        if !selectedAspectRatio.isEmpty, !currentAspectRatios.isEmpty {
            parts.append(aspectRatioLabel(selectedAspectRatio))
        }
        if selectedType == .image, imageModel.maxImages > 1, selectedNumImages > 1 {
            parts.append("×\(selectedNumImages)")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var upscaleSourceFPSLabel: String {
        upscaleSource?.sourceFPS.map { "\(max(1, Int($0.rounded()))) FPS" } ?? L10n.string("Original FPS")
    }

    private func resolutionLabel(_ id: String) -> String {
        selectedType == .image ? ImageModelConfig.resolutionDisplayLabel(id) : id
    }

    private func aspectRatioLabel(_ id: String) -> String {
        selectedType == .image ? ImageModelConfig.aspectRatioDisplayLabel(id) : id
    }

    var settingsButton: some View {
        Button { showSettingsPopover.toggle() } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(settingsSummary)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if supportsAudioToggle {
                    Image(systemName: generateAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: AppTheme.FontSize.xxs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
            settingsPopoverContent
        }
    }

    @ViewBuilder
    private var settingsPopoverContent: some View {
        if selectedType == .upscale {
            ScrollView {
                upscaleSettingsContent
                    .padding(AppTheme.Spacing.lg)
            }
            .frame(width: GenerationSettingsLayout.upscalePopoverWidth)
            .frame(maxHeight: GenerationSettingsLayout.upscalePopoverMaxHeight)
        } else {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                if selectedType == .video {
                    settingsPicker(L10n.string("Duration"), selection: $selectedDuration, options: videoModel.durations) { "\($0)s" }
                }
                if selectedType == .audio, !audioUsesSource {
                    if let durations = audioModel.durations {
                        settingsPicker(L10n.string("Duration"), selection: $selectedAudioDuration, options: durations) { "\($0)s" }
                    } else if let range = audioModel.durationRange {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text(L10n.string("Duration"))
                                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                            ScrubbableNumberField(
                                value: Double(selectedAudioDuration),
                                range: Double(range.minimum)...Double(range.maximum),
                                format: "%.0f",
                                valueSuffix: " s",
                                dragValueAdjustment: { $0.rounded() },
                                onChanged: { selectedAudioDuration = Int($0.rounded()) }
                            ) { selectedAudioDuration = Int($0.rounded()) }
                            .help(L10n.string("Duration (\(range.minimum)-\(range.maximum) seconds)"))
                        }
                    }
                }
                if !currentAspectRatios.isEmpty {
                    settingsPicker(
                        L10n.string("Aspect Ratio"),
                        selection: $selectedAspectRatio,
                        options: currentAspectRatios,
                        gridMinWidth: selectedType == .image ? GenerationSettingsLayout.imageAspectGridMinWidth : nil
                    ) {
                        aspectRatioLabel($0)
                    }
                }
                if let resolutions = currentResolutions {
                    settingsPicker(L10n.string("Resolution"), selection: $selectedResolution, options: resolutions) { resolutionLabel($0) }
                }
                if let qualities = currentQualities {
                    settingsPicker(L10n.string("Quality"), selection: $selectedQuality, options: qualities) { $0.capitalized }
                }
                if selectedType == .image, imageModel.maxImages > 1 {
                    settingsPicker(
                        L10n.string("Count"),
                        selection: $selectedNumImages,
                        options: Array(1...imageModel.maxImages)
                    ) { "\($0)" }
                }
                if selectedType == .audio && audioModel.supportsInstrumental {
                    Toggle(L10n.string("Instrumental"), isOn: $instrumental)
                        .controlSize(.small)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                if selectedType == .audio && audioModel.supportsMultilingual {
                    Toggle(L10n.string("Multilingual"), isOn: $multilingual)
                        .controlSize(.small)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .help(L10n.string("Use for non-English or mixed-language audio."))
                }
                if selectedType == .video, videoModel.audioDiscountRate != nil {
                    let discount = videoModel.audioDiscount(for: effectiveResolution)
                    let savings = discount.map { Int(((1 - $0) * 100).rounded()) }
                    Toggle(L10n.string("Generate audio"), isOn: $generateAudio)
                        .controlSize(.small)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .help(savings.map { L10n.string("Turn off to save \($0)% on generation cost.") }
                            ?? L10n.string("Turn off to skip audio generation."))
                }
            }
            .padding(AppTheme.Spacing.lg)
            .frame(width: selectedType == .image
                ? GenerationSettingsLayout.imagePopoverWidth
                : GenerationSettingsLayout.popoverWidth)
        }
    }

    func settingsPicker<T: Hashable>(
        _ label: String,
        selection: Binding<T>,
        options: [T],
        gridMinWidth: CGFloat? = nil,
        format: @escaping (T) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(verbatim: label)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            if options.count <= 5, gridMinWidth == nil {
                Picker(String(), selection: selection) {
                    ForEach(options, id: \.self) { Text(format($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            } else {
                let columns = gridMinWidth.map { [GridItem(.adaptive(minimum: $0), spacing: AppTheme.Spacing.xs)] }
                    ?? Array(repeating: GridItem(.flexible(), spacing: AppTheme.Spacing.xs), count: options.count == 6 ? 3 : 5)
                LazyVGrid(columns: columns, spacing: AppTheme.Spacing.xs) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            selection.wrappedValue = option
                        } label: {
                            Text(format(option))
                                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                                .foregroundStyle(selection.wrappedValue == option ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: GenerationSettingsLayout.gridButtonMinHeight)
                                .padding(.horizontal, AppTheme.Spacing.xs)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                        .fill(selection.wrappedValue == option
                                            ? AppTheme.Interaction.fill(AppTheme.Opacity.soft)
                                            : AppTheme.Interaction.fill(AppTheme.Opacity.subtle))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
