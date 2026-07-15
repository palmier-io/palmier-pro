import SwiftUI

struct CaptionTab: View {
    @Environment(EditorViewModel.self) var editor
    @Bindable private var account = AccountService.shared

    @State private var style: TextStyle = CaptionTab.defaultStyle
    @State private var center = AppTheme.Caption.defaultCenter

    private static var defaultStyle: TextStyle {
        var s = TextStyle(fontSize: AppTheme.Caption.defaultFontSize)
        s.shadow.enabled = false
        return s
    }
    @State private var selectedTrackId: String?
    @State private var selectedClipTargets: [String] = []
    @State private var provider: TranscriptionProvider = .cloud
    @State private var animationPreset: TextAnimation.Preset = .none
    @State private var animationHighlight: TextStyle.RGBA = TextAnimation.defaultHighlight
    @State private var censorProfanity = false
    @State private var maxWords: Int?
    @State private var locale: Locale?
    @State private var supportedLocales: [Locale] = []
    @State private var isGenerating = false
    @State private var estimatedCloudCost: Int?
    @State private var note: String?
    @State private var sourceExpanded = true
    @State private var settingsExpanded = true
    @State private var styleExpanded = false
    @State private var animationExpanded = false
    @State private var placementExpanded = true

    private static let previewText = "Captions will look like this"

    private var aspect: CGFloat { CGFloat(editor.timeline.width) / CGFloat(max(1, editor.timeline.height)) }

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
        if !selectedClipTargets.isEmpty { return "Selected Clips · \(selectedClipTargets.count)" }
        return editor.captionTargets(ids: []).isEmpty ? "No audio" : "Auto"
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
        guard account.isSignedIn else { return "Sign in to use Cloud." }
        return nil
    }
    private var canGenerateCaptions: Bool {
        effectiveCount > 0 && !isGenerating && cloudModeUnavailableMessage == nil
    }
    private var costEstimateKey: String {
        "\(provider.rawValue)|\(sourceClipIds.joined(separator: ","))|\(isAutoSource)|\(locale?.identifier ?? "")"
    }
    private var costHelpText: String {
        guard let cost = estimatedCloudCost else { return "Estimated cost. Actual billing may differ slightly." }
        guard cost > 0 else { return "Cached — no credits used." }
        guard let remaining = remainingCloudCredits else { return "\(CostEstimator.format(cost)) estimated. Actual billing may differ." }
        if cost > remaining { return "\(CostEstimator.format(cost)) needed. Only \(remaining.formatted()) remaining." }
        return "\(CostEstimator.format(cost)). \((remaining - cost).formatted()) remaining after this generation."
    }

    private static let translateLanguages = [
        "Spanish", "French", "German", "Italian", "Portuguese",
        "Japanese", "Korean", "Chinese", "Hindi", "Arabic"
    ]

    private var sourceSummary: String {
        guard let selectedTrackId else { return automaticSourceSummary }
        guard let index = editor.timeline.tracks.firstIndex(where: { $0.id == selectedTrackId }) else { return "No track" }
        return "\(trackTitle(index)) · \(sourceClipIds.count)"
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
                        placementSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }

                generateBar
            }
            if isGenerating {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                GeneratingOverlay(label: "Transcribing…", size: .preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
        .task {
            guard supportedLocales.isEmpty else { return }
            supportedLocales = (await Transcription.supportedLocales())
                .sorted { languageName($0) < languageName($1) }
        }
        .onAppear { rememberSelectedClipTargets() }
        .onChange(of: editor.selectedClipIds) { _, _ in rememberSelectedClipTargets() }
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
        EditorPanelGroup("Source", isExpanded: $sourceExpanded) {
            InspectorRow(
                label: "Source",
                labelHelp: "Uses selected clips when available, otherwise all captionable audio. Choose a track to limit captions.",
                onReset: {
                    selectedTrackId = nil
                    selectedClipTargets = []
                }
            ) { sourceMenu }
            InspectorRow(
                label: "Mode",
                labelHelp: "Local runs with Apple's SpeechAnalyzer. Cloud uses credits and a more accurate model with more capabilities.",
                onReset: { provider = .cloud }
            ) { providerPicker }
        }
    }

    private var settingsSection: some View {
        EditorPanelGroup("Settings", isExpanded: $settingsExpanded) {
            InspectorRow(label: "Language", onReset: { locale = nil }) {
                Menu {
                    Button("Auto") { locale = nil }
                    if !supportedLocales.isEmpty {
                        Divider()
                        ForEach(supportedLocales, id: \.identifier) { loc in
                            Button(languageName(loc)) { locale = loc }
                        }
                    }
                } label: { EditorMenuValue(text: locale.map(languageName) ?? "Auto", expanded: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
                .frame(maxWidth: .infinity)
            }
            InspectorRow(
                label: "Max words",
                labelHelp: "Cap the words shown per caption. None fits each line to the box.",
                onReset: { maxWords = nil }
            ) {
                Menu {
                    Button("None") { maxWords = nil }
                    ForEach(1...8, id: \.self) { n in
                        Button("\(n)") { maxWords = n }
                    }
                } label: { EditorMenuValue(text: maxWords.map(String.init) ?? "None", expanded: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
                .frame(maxWidth: .infinity)
            }
            InspectorRow(label: "Censor profanity", onReset: { censorProfanity = false }) {
                Toggle("", isOn: $censorProfanity)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityLabel("Censor profanity")
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
                Text("No Tracks")
            } else {
                ForEach(captionTrackIndices, id: \.self) { index in
                    if editor.timeline.tracks.indices.contains(index) {
                        let track = editor.timeline.tracks[index]
                        let count = editor.captionTargets(trackIds: [track.id]).count
                        Button {
                            selectedTrackId = track.id
                        } label: {
                            Label(
                                "\(trackTitle(index)) · \(count) \(count == 1 ? "clip" : "clips")",
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
        "Cloud auto-detects languages, produces more accurate transcripts, can identify speakers, and uses 25 credits/hr when a transcript is not cached."
    }

    private func providerOption(_ option: TranscriptionProvider, title: String) -> some View {
        let selected = provider == option
        return Button {
            provider = option
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                RadioIndicator(selected: selected, size: AppTheme.IconSize.xxs, innerPadding: AppTheme.Spacing.xxs)
                Text(title)
                    .font(.system(size: AppTheme.FontSize.sm, weight: selected ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium))
                    .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(option == .cloud ? cloudCreditHelp : "Local runs with Apple's SpeechAnalyzer.")
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
        Locale.current.localizedString(forIdentifier: loc.identifier) ?? loc.identifier(.bcp47)
    }

    private var styleSection: some View {
        TextStyleControls(
            selection: TextStyleSelection(styles: [style], fallback: Self.defaultStyle),
            defaults: Self.defaultStyle,
            styleExpanded: $styleExpanded,
            groupsExpandedByDefault: false,
            actions: styleActions
        )
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
        EditorPanelGroup("Animation", isExpanded: $animationExpanded) {
            CaptionPresetGallery(selection: $animationPreset, highlight: animationHighlight)
            if animationPreset.usesHighlight {
                InspectorRow(
                    label: "Highlight",
                    labelHelp: "Color for the active word.",
                    onReset: { animationHighlight = TextAnimation.defaultHighlight }
                ) {
                    ColorField(displayColor: animationHighlight.swiftUIColor, onUserChange: { animationHighlight = TextStyle.RGBA($0) })
                }
            }
        }
    }

    private var placementSection: some View {
        EditorPanelGroup("Placement", isExpanded: $placementExpanded) {
            previewBox
            HStack(spacing: AppTheme.Spacing.mdLg) {
                Spacer(minLength: AppTheme.Spacing.xs)
                posField("X", value: center.x) { center.x = $0 }
                posField("Y", value: center.y) { center.y = $0 }
            }
        }
    }

    private var agentMenu: some View {
        EditorAgentMenu(
            help: "Let Agent create captions for you. Choose a predefined task, or ask Agent in the chat."
        ) {
            Button {
                captionTask("remove filler words (um, uh, er, like, you know) from the captions, keeping each caption's timing unchanged.")
            } label: { Label("Remove filler words", systemImage: "text.badge.minus") }
            Button {
                captionTask("fix any misspelled names, brand names, or technical jargon in the captions using the surrounding context, keeping timing unchanged.")
            } label: { Label("Fix names & jargon", systemImage: "checkmark.bubble") }
            Button {
                captionTask("add relevant emoji to the captions, keeping the text and timing otherwise unchanged.")
            } label: { Label("Add emoji", systemImage: "face.smiling") }
            Menu {
                ForEach(Self.translateLanguages, id: \.self) { language in
                    Button(language) {
                        captionTask("translate the captions to \(language), keeping each caption's timing unchanged.")
                    }
                }
            } label: { Label("Translate", systemImage: "globe") }
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

    private var previewBox: some View {
        ZStack {
            AppTheme.Background.previewCanvasColor
            centerGuides
            GeometryReader { geo in
                CaptionAnimatedPreview(
                    text: Self.previewText, style: style, center: center,
                    preset: animationPreset, highlight: animationHighlight,
                    canvas: CGSize(width: max(1, editor.timeline.width), height: max(1, editor.timeline.height)),
                    size: geo.size
                )
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: AppTheme.ComponentSize.captionPreviewMaxHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
        )
    }

    private var centerGuides: some View {
        GeometryReader { geo in
            let guide = AppTheme.Accent.timecodeColor.opacity(AppTheme.Opacity.prominent)
            ZStack {
                if center.x == AppTheme.Caption.centerSnapValue {
                    Rectangle().fill(guide).frame(width: AppTheme.BorderWidth.hairline, height: geo.size.height)
                }
                if center.y == AppTheme.Caption.centerSnapValue {
                    Rectangle().fill(guide).frame(width: geo.size.width, height: AppTheme.BorderWidth.hairline)
                }
            }
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .allowsHitTesting(false)
    }

    private func snapCenter(_ v: Double) -> CGFloat {
        let centerValue = Double(AppTheme.Caption.centerSnapValue)
        return CGFloat(abs(v - centerValue) < AppTheme.Caption.centerSnapThreshold ? centerValue : v)
    }

    private func posField(_ label: String, value: CGFloat, onChange: @escaping (CGFloat) -> Void) -> some View {
        HStack(spacing: AppTheme.Spacing.xxs) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            ScrubbableNumberField(
                value: Double(value),
                range: AppTheme.Caption.minPosition...AppTheme.Caption.maxPosition,
                displayMultiplier: 100,
                format: "%.0f",
                valueSuffix: "%",
                onChanged: { onChange(snapCenter($0)) }
            ) { onChange(snapCenter($0)) }
        }
    }

    private var generateBar: some View {
        EditorActionFooter(message: note) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Button(action: generate) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text(cloudModeUnavailableMessage ?? "Generate Captions")
                        if cloudModeUnavailableMessage == nil, provider == .cloud, let cost = estimatedCloudCost {
                            Image(systemName: "dollarsign.circle.fill").font(.system(size: AppTheme.FontSize.xs))
                            Text("\(cost)").monospacedDigit()
                        }
                    }
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorPrimary)
                .focusable(false)
                .disabled(!canGenerateCaptions)
                .help(provider == .cloud ? costHelpText : "")

                agentMenu
            }
        }
    }

    private func generate() {
        note = nil
        let sourceIds = sourceClipIds
        if selectedTrackId != nil && sourceIds.isEmpty {
            note = "No audio selected."
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
                if try await editor.generateCaptions(for: request).isEmpty { note = "No speech detected." }
            } catch {
                note = error.localizedDescription
            }
        }
    }

    private func cloudUnavailableMessage(cost: Int?, provider mode: TranscriptionProvider? = nil) -> String? {
        guard (mode ?? provider) == .cloud else { return nil }
        guard account.isSignedIn else { return "Sign in to use Cloud." }
        guard let cost else { return nil }
        guard cost > 0 else { return nil }
        guard let remaining = remainingCloudCredits else { return nil }
        guard remaining > 0 else { return "Add credits to use Cloud." }
        if cost > remaining {
            return "\(CostEstimator.format(cost)) needed. Only \(remaining.formatted()) remaining."
        }
        return nil
    }
}
