import SwiftUI

struct MusicTab: View {
    @Environment(EditorViewModel.self) var editor
    @Bindable private var account = AccountService.shared

    @State private var selectedModelId: String?
    @State private var mode: MusicGenerationSubmission.Mode = .videoToMusic
    @State private var prompt: String = ""
    @State private var textDuration: Double = 90
    @State private var isGenerating = false
    @State private var generatingLabel = "Generating..."
    @State private var note: String?

    private var models: [AudioModelConfig] {
        AudioModelConfig.allModels.filter { $0.inputs.contains(.video) && $0.category == .music }
    }

    private var model: AudioModelConfig? {
        if let id = selectedModelId, let m = models.first(where: { $0.id == id }) { return m }
        return models.first
    }

    private func supportsTextMode(_ m: AudioModelConfig) -> Bool {
        m.category == .music && m.inputs.contains(.text)
    }

    /// Text mode only when the selected model supports text-to-music.
    private var effectiveMode: MusicGenerationSubmission.Mode {
        (model.map(supportsTextMode) ?? false) ? mode : .videoToMusic
    }
    private var isTextMode: Bool { effectiveMode == .textToMusic }

    private var textDurationRange: ClosedRange<Double> {
        guard let range = model?.durationRange else { return 1...600 }
        return Double(range.minimum)...Double(range.maximum)
    }

    private var defaultTextDuration: Double {
        Double(model?.durationRange?.defaultValue ?? 90)
    }

    private var source: EditorViewModel.TimelineSpan? { editor.selectedTimelineSpan() }

    private var spanSeconds: Double {
        guard let source else { return 0 }
        return Double(source.frameCount) / Double(max(1, editor.timeline.fps))
    }

    /// Where a text-to-music clip lands: the marked range start, else the playhead.
    private var textPlacementFrame: Int {
        editor.validSelectedTimelineRange?.startFrame ?? editor.currentFrame
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var costDuration: Int {
        isTextMode ? Int(textDuration.rounded()) : Int(spanSeconds.rounded())
    }

    private var estimatedCost: Int? {
        guard let model, costDuration > 0 else { return nil }
        return CostEstimator.audioCost(
            model: model,
            prompt: trimmedPrompt,
            durationSeconds: costDuration,
            input: isTextMode ? .text : .video
        )
    }

    private var validationNote: String? {
        guard let model else { return "No music models available." }
        if isTextMode {
            if trimmedPrompt.isEmpty { return "Describe the music to generate." }
            let params = AudioGenerationParams(
                prompt: trimmedPrompt,
                voice: nil,
                lyrics: nil,
                styleInstructions: nil,
                instrumental: false,
                durationSeconds: costDuration
            )
            if let issue = model.validate(params: params) { return issue }
        } else {
            guard source != nil else {
                return "Add video to the timeline, then mark a range to score only part of it."
            }
            if let issue = model.validate(spanSeconds: spanSeconds) { return issue }
        }
        if let cost = estimatedCost, cost > AccountService.shared.remainingCredits,
           AccountService.shared.budgetCredits != nil {
            return "\(cost) credits needed. Only \(AccountService.shared.remainingCredits.formatted()) remaining."
        }
        return nil
    }

    private var canGenerate: Bool {
        model != nil && validationNote == nil && !isGenerating
    }

    private var generateLabel: String {
        if let cost = estimatedCost, cost > 0 { return "Generate · \(CostEstimator.format(cost))" }
        return "Generate"
    }

    private var sourceSummary: String {
        guard let source else { return "No video" }
        let scope = editor.validSelectedTimelineRange != nil ? "" : "Whole timeline · "
        return "\(scope)\(clock(source.startFrame)) – \(clock(source.startFrame + source.frameCount)) · \(String(format: "%.1fs", spanSeconds))"
    }

    var body: some View {
        ZStack {
            VStack(spacing: AppTheme.Spacing.zero) {
                ScrollView {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
                        musicSection
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                generateBar
            }
            if isGenerating {
                AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent)
                GeneratingOverlay(label: generatingLabel, size: .preview)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
    }

    private var musicSection: some View {
        EditorPanelGroup("Music") {
            sourceControls
            modelControl
            promptControl
        }
    }

    @ViewBuilder
    private var sourceControls: some View {
        if model.map(supportsTextMode) == true {
            InspectorRow(label: "Input", onReset: { mode = .videoToMusic }) {
                Menu {
                    Button("Video to Music") { mode = .videoToMusic }
                    Button("Text to Music") { mode = .textToMusic }
                } label: { EditorMenuValue(text: modeLabel(effectiveMode), expanded: true) }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
                .frame(maxWidth: .infinity)
            }
        }
        if isTextMode {
            InspectorRow(
                label: "Duration",
                labelHelp: "Length of the generated music. It's placed at the playhead, or at the marked range start.",
                onReset: { textDuration = defaultTextDuration }
            ) {
                ScrubbableNumberField(
                    value: textDuration,
                    range: textDurationRange,
                    format: "%.0f",
                    valueSuffix: " s",
                    dragValueAdjustment: { $0.rounded() },
                    onChanged: { textDuration = $0.rounded() }
                ) { textDuration = $0.rounded() }
            }
        } else {
            InspectorRow(
                label: "Video",
                labelHelp: "Uses the whole timeline by default. Mark a range on the timeline to score only that span."
            ) { valueText(sourceSummary) }
        }
    }

    private func modeLabel(_ m: MusicGenerationSubmission.Mode) -> String {
        switch m {
        case .videoToMusic: "Video to Music"
        case .textToMusic: "Text to Music"
        }
    }

    private var modelControl: some View {
        InspectorRow(label: "Model", onReset: { selectModel(nil) }) {
            Menu {
                ForEach(models, id: \.id) { m in
                    Button(m.displayName) { selectModel(m) }
                }
            } label: {
                EditorMenuValue(text: model?.displayName ?? "None", expanded: true)
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).focusable(false)
            .frame(maxWidth: .infinity)
        }
    }

    private func selectModel(_ selectedModel: AudioModelConfig?) {
        selectedModelId = selectedModel?.id
        guard let selectedModel = selectedModel ?? models.first else { return }
        if let range = selectedModel.durationRange,
           !(Double(range.minimum)...Double(range.maximum)).contains(textDuration) {
            textDuration = Double(range.defaultValue)
        } else if let durations = selectedModel.durations,
                  !durations.contains(Int(textDuration.rounded())) {
            textDuration = Double(durations.first ?? 90)
        }
    }

    private var promptControl: some View {
        InspectorRow(label: "Prompt") {
            TextField(model?.promptLabel ?? "", text: $prompt, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(2...5)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(AppTheme.Spacing.smMd)
                .editorValueField()
        }
    }

    private var generateBar: some View {
        EditorActionFooter(message: note ?? validationNote) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Button(action: generate) {
                    Text(generateLabel)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.editorPrimary)
                .focusable(false)
                .disabled(!canGenerate || !account.aiAllowed)
                .help(account.aiAllowed ? "" : "Sign in to generate")

                agentMenu
            }
        }
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
            .lineLimit(1)
    }

    private func clock(_ frame: Int) -> String {
        let total = Double(frame) / Double(max(1, editor.timeline.fps))
        let m = Int(total) / 60
        let s = Int(total) % 60
        return String(format: "%d:%02d", m, s)
    }

    private var agentMenu: some View {
        EditorAgentMenu(
            help: "Let Agent generate music for you. Choose a starter, or ask Agent in the chat."
        ) {
            Button {
                musicTask("Score my timeline with music that matches the visuals. Use a video-to-music model on the full timeline span so the music follows the edit, and place it on an audio track.")
            } label: { Label("Generate music for the timeline", systemImage: "music.note") }
            Menu {
                ForEach(["Cinematic", "Upbeat", "Ambient", "Tense", "Lo-fi"], id: \.self) { mood in
                    Button(mood) {
                        musicTask("Generate \(mood.lowercased()) music for my timeline and place it on an audio track aligned to the edit.")
                    }
                }
            } label: { Label("Mood", systemImage: "slider.horizontal.3") }
        }
    }

    private func musicTask(_ prompt: String) {
        let service = editor.agentService
        service.newChat()
        service.draft = prompt
        editor.agentPanelVisible = true
    }

    private func generate() {
        note = nil
        guard let model else { return }
        let trimmed = trimmedPrompt.isEmpty ? nil : trimmedPrompt
        let submission: MusicGenerationSubmission
        if isTextMode {
            let frameCount = max(1, Int(textDuration * Double(max(1, editor.timeline.fps))))
            submission = MusicGenerationSubmission(
                mode: .textToMusic, model: model, prompt: trimmed,
                source: .init(startFrame: textPlacementFrame, frameCount: frameCount),
                spanSeconds: textDuration, name: nil
            )
        } else {
            guard let source else { return }
            submission = MusicGenerationSubmission(
                mode: .videoToMusic, model: model, prompt: trimmed,
                source: source, spanSeconds: spanSeconds, name: nil
            )
        }

        isGenerating = true
        generatingLabel = (isTextMode ? MusicGenerationSubmission.Phase.generating : .exporting).label
        Task {
            do {
                try await submission.run(
                    service: editor.generationService,
                    projectURL: editor.projectURL,
                    editor: editor,
                    onPhase: { generatingLabel = $0.label },
                    onFinished: { isGenerating = false }
                )
            } catch {
                note = error.localizedDescription
                isGenerating = false
            }
        }
    }
}
