import SwiftUI

struct CaptionTab: View {
    @Environment(EditorViewModel.self) var editor
    @Bindable private var account = AccountService.shared

    @State private var style: TextStyle = .caption
    @State private var center = AppTheme.Caption.defaultCenter
    @State private var selectedTrackId: String?
    @State private var selectedClipTargets: [String] = []
    @State private var provider: TranscriptionProvider = .cloud
    @State private var animationPreset: TextAnimation.Preset = .none
    @State private var animationHighlight: TextStyle.RGBA = TextAnimation.defaultHighlight
    @State private var censorProfanity = false
    @State private var maxWords: Int?
    @State private var maxCharacters: Int?
    @State private var maximumGapSeconds = CaptionGapSettings.default.maximumGapSeconds
    @State private var locale: Locale?
    @State private var supportedLocales: [Locale] = []
    @State private var isGenerating = false
    @State private var estimatedCloudCost: Int?
    @State private var note: String?
    @State private var sourceExpanded = true
    @State private var settingsExpanded = true
    @State private var styleExpanded = false
    @State private var animationExpanded = false

    private static let previewText = L10n.key("Captions will look like this")
    private static let maxWordRange = 0.0...50.0
    private static let maxCharacterRange = 0.0...200.0

    private var previewConfiguration: CaptionPreviewConfiguration {
        CaptionPreviewConfiguration(
            text: L10n.string(key: Self.previewText),
            style: style,
            center: center,
            preset: animationPreset,
            highlight: animationHighlight
        )
    }

    private var liveTargets: [String] {
        let sel = editor.selectedClipIds
        guard !sel.isEmpty else { return [] }
        return editor.captionTargets(ids: Array(sel)).map(\.id)
    }
    private var isAutoSource: Bool { selectedTrackId == nil && selectedClipTargets.isEmpty }
    private var sourceClipIds: [String] {
        if let selectedTrackId { return editor.captionTargets(trackIds: [selectedTrackId]).map(\.id) }
        return selectedClipTargets   // Auto resolves its source during generation
    }
    private var automaticSourceSummary: String {
        if !selectedClipTargets.isEmpty { return L10n.string("Selected Clips · \(selectedClipTargets.count)") }
        return editor.captionTargets(ids: []).isEmpty ? L10n.string("No audio") : L10n.string("Auto")
    }
    private var effectiveCount: Int {
        isAutoSource ? editor.captionTargets(ids: []).count : sourceClipIds.count
    }
    private var captionTrackIndices: [Int] {
        editor.timeline.tracks.indices.filter { !editor.captionTargets(trackIds: [editor.timeline.tracks[$0].id]).isEmpty }
    }
    private var remainingCloudCredits: Int? {
        account.budgetCredits == nil ? nil : account.remainingCredits
    }
    private var cloudModeUnavailableMessage: String? {
        guard provider == .cloud else { return nil }
        guard account.isSignedIn else { return L10n.string("Sign in to use Cloud.") }
        return nil
    }
    private var canGenerateCaptions: Bool {
        effectiveCount > 0 && !isGenerating && cloudModeUnavailableMessage == nil
    }
    private var costEstimateKey: String {
        "\(provider.rawValue)|\(sourceClipIds.joined(separator: ","))|\(isAutoSource)|\(locale?.identifier ?? "")"
    }
    private var costHelpText: String {
        guard let cost = estimatedCloudCost else {
            return L10n.string("Estimated cost. Actual billing may differ slightly.")
        }
        guard cost > 0 else { return L10n.string("Cached — no credits used.") }
        guard let remaining = remainingCloudCredits else {
            return CostEstimator.localizedEstimate(cost)
        }
        if cost > remaining {
            return CostEstimator.localizedInsufficientCredits(cost, remaining: remaining)
        }
        return CostEstimator.localizedRemainingCredits(cost, remaining: remaining - cost)
    }

    private static let translateLanguages = [
        (code: "es", promptName: "Spanish"),
        (code: "fr", promptName: "French"),
        (code: "de", promptName: "German"),
        (code: "it", promptName: "Italian"),
        (code: "pt", promptName: "Portuguese"),
        (code: "ja", promptName: "Japanese"),
        (code: "ko", promptName: "Korean"),
        (code: "zh-Hans", promptName: "Chinese"),
        (code: "hi", promptName: "Hindi"),
        (code: "ar", promptName: "Arabic"),
    ]

    private var sourceSummary: String {
        guard let selectedTrackId else { return automaticSourceSummary }
        guard let index = editor.timeline.tracks.firstIndex(where: { $0.id == selectedTrackId }) else { return L10n.string("No track") }
        return L10n.string("\(trackTitle(index)) · \(sourceClipIds.count)")
    }

    var body: some View {
        ZStack {
            VStack(spacing: AppTheme.Spacing.zero) {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                        sourceSection
                        settingsSection
                        styleSection
                        animationSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                generateBar
            }
            if isGenerating {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                GeneratingOverlay(label: L10n.string("Transcribing…"), size: .preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
        .task {
            guard supportedLocales.isEmpty else { return }
            supportedLocales = (await Transcription.supportedLocales())
                .sorted { languageName($0) < languageName($1) }
        }
        .onAppear {
            rememberSelectedClipTargets()
            editor.captionPreviewCenterChange = { center = $0 }
            showCaptionPreview()
        }
        .onDisappear {
            editor.captionPreviewConfiguration = nil
            editor.captionPreviewCenterChange = nil
        }
        .onChange(of: previewConfiguration) { _, _ in showCaptionPreview() }
        .onChange(of: editor.mediaPanelVisible) { _, _ in showCaptionPreview() }
        .onChange(of: editor.selectedClipIds) { _, _ in
            guard !editor.isMarqueeSelecting else { return }
            rememberSelectedClipTargets()
        }
        .onChange(of: editor.isMarqueeSelecting) { wasSelecting, isSelecting in
            guard wasSelecting, !isSelecting else { return }
            rememberSelectedClipTargets()
        }
        .task(id: costEstimateKey) {
            estimatedCloudCost = nil
            guard provider == .cloud, effectiveCount > 0 else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            let request = EditorViewModel.CaptionRequest(sourceClipIds: sourceClipIds, autoDetect: isAutoSource, locale: locale, provider: .cloud)
            let cost = await editor.captionCloudCreditCost(for: request)
            guard !Task.isCancelled else { return }
            estimatedCloudCost = cost
        }
    }

    private var sourceSection: some View {
        EditorPanelGroup(
            L10n.string("Source"),
            isExpanded: $sourceExpanded,
            headerAccessory: { captionPreviewToggle }
        ) {
            InspectorRow(
                label: L10n.string("Source"),
                labelHelp: L10n.string("Uses selected clips when available, otherwise all captionable audio. Choose a track to limit captions."),
                onReset: {
                    selectedTrackId = nil
                    selectedClipTargets = []
                }
            ) { sourceMenu }
            InspectorRow(
                label: L10n.string("Mode"),
                labelHelp: L10n.string("Local runs with Apple's SpeechAnalyzer. Cloud uses credits and a more accurate model with more capabilities."),
                onReset: { provider = .cloud }
            ) { providerPicker }
        }
    }

    private var captionPreviewToggle: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Text(L10n.string("Preview"))
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Toggle(
                String(),
                isOn: Binding(
                    get: { editor.captionPreviewEnabled },
                    set: { editor.captionPreviewEnabled = $0 }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.strong))
            .accessibilityLabel(L10n.string("Preview"))
        }
        .help(L10n.string("Preview"))
    }

    private var settingsSection: some View {
        EditorPanelGroup(L10n.string("Settings"), isExpanded: $settingsExpanded) {
            InspectorRow(label: L10n.string("Language"), onReset: { locale = nil }) {
                Menu {
                    Button(L10n.string("Auto")) { locale = nil }
                    if !supportedLocales.isEmpty {
                        Divider()
                        ForEach(supportedLocales, id: \.identifier) { loc in
                            Button(languageName(loc)) { locale = loc }
                        }
                    }
                } label: { EditorMenuValue(text: locale.map(languageName) ?? L10n.string("Auto"), expanded: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
                .frame(maxWidth: .infinity)
            }
            InspectorRow(
                label: L10n.string("Max words"),
                labelHelp: L10n.string("Cap the words shown per caption. None fits each line to the box."),
                onReset: { maxWords = nil }
            ) {
                ScrubbableNumberField(
                    value: Double(maxWords ?? 0),
                    range: Self.maxWordRange,
                    dragValueAdjustment: { $0.rounded() },
                    displayTextOverride: { $0 < 1 ? L10n.string("None") : nil },
                    onChanged: updateMaxWords,
                    onCommit: updateMaxWords
                )
                .accessibilityLabel(L10n.string("Max words"))
            }
            InspectorRow(
                label: L10n.string("Max characters"),
                labelHelp: L10n.string("Cap characters per caption, including spaces and punctuation. A single word may exceed the limit."),
                onReset: { maxCharacters = nil }
            ) {
                ScrubbableNumberField(
                    value: Double(maxCharacters ?? 0),
                    range: Self.maxCharacterRange,
                    dragValueAdjustment: { $0.rounded() },
                    displayTextOverride: { $0 < 1 ? L10n.string("None") : nil },
                    onChanged: updateMaxCharacters,
                    onCommit: updateMaxCharacters
                )
                .accessibilityLabel(L10n.string("Max characters"))
            }
            InspectorRow(
                label: L10n.string("Close gaps"),
                labelHelp: L10n.string("Extends captions across short gaps and holds the final caption."),
                onReset: {
                    maximumGapSeconds = CaptionGapSettings.default.maximumGapSeconds
                }
            ) {
                ScrubbableNumberField(
                    value: maximumGapSeconds,
                    range: CaptionGapSettings.maximumGapRange,
                    displayMultiplier: 1_000,
                    format: "%.0f",
                    valueSuffix: " ms",
                    dragSensitivity: 10,
                    dragValueAdjustment: { ($0 / 0.05).rounded() * 0.05 },
                    onChanged: { maximumGapSeconds = $0 },
                    onCommit: { maximumGapSeconds = $0 }
                )
                .accessibilityLabel(L10n.string("Close gaps"))
            }
            InspectorRow(label: L10n.string("Censor profanity"), onReset: { censorProfanity = false }) {
                Toggle(String(), isOn: $censorProfanity)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel(L10n.string("Censor profanity"))
                    .tint(AppTheme.Text.primaryColor.opacity(AppTheme.Opacity.strong))
                    .disabled(provider == .cloud)
                    .opacity(provider == .cloud ? AppTheme.Opacity.muted : AppTheme.Opacity.opaque)
            }
        }
    }

    private var sourceMenu: some View {
        Menu {
            Button {
                selectedTrackId = nil
            } label: {
                Label(automaticSourceSummary, systemImage: selectedTrackId == nil ? "checkmark" : "")
            }

            Divider()

            if captionTrackIndices.isEmpty {
                Text(L10n.string("No Tracks"))
            } else {
                ForEach(captionTrackIndices, id: \.self) { index in
                    if editor.timeline.tracks.indices.contains(index) {
                        let track = editor.timeline.tracks[index]
                        let count = editor.captionTargets(trackIds: [track.id]).count
                        let clipCount = count == 1 ? L10n.string("1 clip") : L10n.string("\(count) clips")
                        Button {
                            selectedTrackId = track.id
                        } label: {
                            Label(
                                L10n.string("\(trackTitle(index)) · \(clipCount)"),
                                systemImage: selectedTrackId == track.id ? "checkmark" : ""
                            )
                        }
                    }
                }
            }
        } label: {
            EditorMenuValue(text: sourceSummary, expanded: true)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
        .frame(maxWidth: .infinity)
    }

    private var providerPicker: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            providerOption(.local, title: TranscriptionProvider.local.label)
            providerOption(.cloud, title: TranscriptionProvider.cloud.label)
        }
        .fixedSize()
    }

    private var cloudCreditHelp: String {
        L10n.string("Cloud auto-detects languages, produces more accurate transcripts, can identify speakers, and uses 25 credits/hr when a transcript is not cached.")
    }

    private func providerOption(_ option: TranscriptionProvider, title: String) -> some View {
        let selected = provider == option
        return Button {
            provider = option
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                RadioIndicator(selected: selected, size: AppTheme.IconSize.xxs, innerPadding: AppTheme.Spacing.xxs)
                Text(L10n.string(key: title))
                    .font(.system(size: AppTheme.FontSize.sm, weight: selected ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium))
                    .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(option == .cloud
            ? cloudCreditHelp
            : L10n.string("Local runs with Apple's SpeechAnalyzer."))
    }

    private func rememberSelectedClipTargets() {
        let targets = liveTargets
        guard !targets.isEmpty || editor.focusedPanel != .media else { return }
        selectedClipTargets = targets
    }

    private func trackTitle(_ index: Int) -> String {
        editor.timelineTrackDisplayLabel(at: index)
    }

    private func languageName(_ loc: Locale) -> String {
        AppLocalization.shared.activeLocale.localizedString(forIdentifier: loc.identifier)
            ?? loc.identifier(.bcp47)
    }

    private func translationLanguageName(_ identifier: String) -> String {
        AppLocalization.shared.activeLocale.localizedString(forLanguageCode: identifier)
            ?? identifier
    }

    private var styleSection: some View {
        TextStyleControls(
            selection: TextStyleSelection(styles: [style], fallback: .caption),
            defaults: .caption,
            styleExpanded: $styleExpanded,
            groupsExpandedByDefault: false,
            actions: styleActions,
            afterAlignment: { captionPositionRow },
            afterColor: { EmptyView() }
        )
    }

    private var captionPositionRow: some View {
        InspectorRow(
            label: L10n.string("Position"),
            onReset: { center = AppTheme.Caption.defaultCenter }
        ) {
            HStack(spacing: AppTheme.Spacing.sm) {
                captionPositionField(
                    value: center.x,
                    canvasLength: max(1, editor.timeline.width),
                    label: "X",
                    onChange: { center.x = $0 }
                )
                captionPositionField(
                    value: center.y,
                    canvasLength: max(1, editor.timeline.height),
                    label: "Y",
                    onChange: { center.y = $0 }
                )
            }
            .fixedSize()
        }
    }

    private func captionPositionField(
        value: CGFloat,
        canvasLength: Int,
        label: String,
        onChange: @escaping (CGFloat) -> Void
    ) -> some View {
        ScrubbableNumberField(
            value: Double(value),
            range: -10...10,
            displayMultiplier: Double(canvasLength),
            format: "%.0f",
            fieldWidth: AppTheme.EditorPanel.compactNumericFieldWidth,
            trailingLabel: label,
            onChanged: { onChange(CaptionPreviewPlacement.snappedCoordinate($0)) }
        ) {
            onChange(CaptionPreviewPlacement.snappedCoordinate($0))
        }
    }

    private var styleActions: TextStyleEditingActions {
        TextStyleEditingActions(
            apply: { _, mutation in mutation(&style) },
            commit: { _, mutation in mutation(&style) },
            commitColor: { _, mutation in mutation(&style) },
            cancelPending: { _ in },
            cancelFontPreview: { originalFont in
                if let originalFont { style.fontName = originalFont }
            }
        )
    }

    private var animationSection: some View {
        EditorPanelGroup(L10n.string("Animation"), isExpanded: $animationExpanded) {
            CaptionPresetGallery(selection: $animationPreset, highlight: animationHighlight)
            if animationPreset.usesHighlight {
                InspectorRow(
                    label: L10n.string("Highlight"),
                    labelHelp: L10n.string("Color for the active word."),
                    onReset: { animationHighlight = TextAnimation.defaultHighlight }
                ) {
                    ColorField(displayColor: animationHighlight.swiftUIColor, onUserChange: { animationHighlight = TextStyle.RGBA($0) })
                }
            }
        }
    }

    private var generateLabel: String {
        if cloudModeUnavailableMessage == nil, provider == .cloud, let cost = estimatedCloudCost, cost > 0 {
            return CostEstimator.localizedGenerateLabel(cost)
        }
        return L10n.string("Generate")
    }

    private var generateHelp: String {
        if let cloudModeUnavailableMessage { return cloudModeUnavailableMessage }
        return provider == .cloud ? costHelpText : String()
    }

    private var agentMenu: some View {
        EditorAgentMenu(
            help: L10n.string("Let Agent create captions for you. Choose a predefined task, or ask Agent in the chat.")
        ) {
            Button {
                captionTask("remove filler words (um, uh, er, like, you know) from the captions, keeping each caption's timing unchanged.")
            } label: { Label(L10n.string("Remove filler words"), systemImage: "text.badge.minus") }
            Button {
                captionTask("fix any misspelled names, brand names, or technical jargon in the captions using the surrounding context, keeping timing unchanged.")
            } label: { Label(L10n.string("Fix names & jargon"), systemImage: "checkmark.bubble") }
            Button {
                captionTask("add relevant emoji to the captions, keeping the text and timing otherwise unchanged.")
            } label: { Label(L10n.string("Add emoji"), systemImage: "face.smiling") }
            Menu {
                ForEach(Self.translateLanguages, id: \.code) { language in
                    Button(translationLanguageName(language.code)) {
                        captionTask("translate the captions to \(language.promptName), keeping each caption's timing unchanged.")
                    }
                }
            } label: { Label(L10n.string("Translate"), systemImage: "globe") }
        }
    }

    private func captionTask(_ task: String) {
        handoff("If the timeline has no captions yet, transcribe the spoken audio and add captions on word boundaries first. Then \(task)")
    }

    private func handoff(_ prompt: String) {
        let service = editor.agentService
        service.newChat()
        service.draft = prompt
        editor.agentPanelVisible = true
    }

    private var generateBar: some View {
        EditorActionFooter(message: note ?? cloudModeUnavailableMessage) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Spacer(minLength: AppTheme.Spacing.zero)
                Button(action: generate) {
                    Text(generateLabel)
                        .lineLimit(1)
                }
                .buttonStyle(.capsule(.prominent))
                .fixedSize()
                .focusable(false)
                .disabled(!canGenerateCaptions)
                .help(generateHelp)

                agentMenu
            }
        }
    }

    private func generate() {
        note = nil
        let sourceIds = sourceClipIds
        if selectedTrackId != nil && sourceIds.isEmpty {
            note = L10n.string("No audio selected.")
            return
        }
        let request = EditorViewModel.CaptionRequest(
            sourceClipIds: sourceIds,
            autoDetect: isAutoSource,
            style: style,
            center: center,
            censorProfanity: provider == .local && censorProfanity,
            locale: locale,
            maxWords: maxWords,
            maxCharacters: maxCharacters,
            gapSettings: CaptionGapSettings(maximumGapSeconds: maximumGapSeconds) ?? .default,
            provider: provider,
            animation: TextAnimation(preset: animationPreset, highlight: animationHighlight)
        )
        Task {
            isGenerating = true
            defer { isGenerating = false }
            do {
                if request.provider == .cloud {
                    if let message = cloudUnavailableMessage(cost: nil, provider: request.provider) {
                        note = message
                        return
                    }
                    let cost = await editor.captionCloudCreditCost(for: request)
                    if let message = cloudUnavailableMessage(cost: cost, provider: request.provider) {
                        note = message
                        return
                    }
                }
                if try await editor.generateCaptions(for: request).isEmpty {
                    note = L10n.string("No speech detected.")
                } else {
                    editor.captionPreviewEnabled = false
                }
            } catch {
                note = localizedCaptionError(error)
            }
        }
    }

    private func showCaptionPreview() {
        editor.captionPreviewConfiguration = editor.mediaPanelVisible ? previewConfiguration : nil
    }

    private func updateMaxCharacters(_ value: Double) {
        let count = Int(value.rounded())
        maxCharacters = count > 0 ? count : nil
    }

    private func updateMaxWords(_ value: Double) {
        let count = Int(value.rounded())
        maxWords = count > 0 ? count : nil
    }

    private func cloudUnavailableMessage(cost: Int?, provider mode: TranscriptionProvider? = nil) -> String? {
        guard (mode ?? provider) == .cloud else { return nil }
        guard account.isSignedIn else { return L10n.string("Sign in to use Cloud.") }
        guard let cost else { return nil }
        guard cost > 0 else { return nil }
        guard let remaining = remainingCloudCredits else { return nil }
        guard remaining > 0 else { return L10n.string("Add credits to use Cloud.") }
        if cost > remaining {
            return CostEstimator.localizedInsufficientCredits(cost, remaining: remaining)
        }
        return nil
    }

    private func localizedCaptionError(_ error: Error) -> String {
        guard let error = error as? TranscriptionError else { return error.localizedDescription }
        switch error {
        case .unsupportedLocale(let identifier):
            return L10n.string("On-device transcription is not available for \(identifier).")
        case .modelInstallFailed(let reason):
            return L10n.string("Could not install the on-device speech model: \(reason)")
        case .decodeFailed:
            return L10n.string("Could not parse transcription result.")
        case .audioExtractionFailed(let reason):
            return L10n.string("Audio extraction failed: \(reason)")
        case .analysisFailed(let reason):
            return L10n.string("Transcription failed: \(reason)")
        }
    }
}
