import SwiftUI

struct GenerationView: View {
    let maxPanelHeight: Double

    @Environment(EditorViewModel.self) var editor
    @Bindable var account = AccountService.shared
    @State var prompt = ""
    @State var selectedType: GenerationType = .video
    @State var selectedVideoModelIndex = 0
    @State var selectedImageModelIndex = 0
    @State var selectedAudioModelIndex = 0
    @State var selectedUpscaleModelIndex = 0
    @State var selectedDuration = 5
    @State var selectedAspectRatio = "16:9"
    @State var selectedResolution = "1080p"
    @State var selectedQuality = "high"
    @State var selectedNumImages = 1

    // Audio extras
    @State var selectedVoice = ""
    @State var lyrics = ""
    @State var styleInstructions = ""
    @State var instrumental = false
    @State var selectedAudioDuration = 30
    @State var selectedTargetLanguage = ""
    @State var generateAudio = true
    @State var upscaleSettings = UpscaleSettings()
    @State var showSettingsPopover = false
    @FocusState private var isPromptFocused: Bool

    // Video frame references
    @State var firstFrame: MediaAsset?
    @State var lastFrame: MediaAsset?
    @State var firstFrameTargeted = false
    @State var lastFrameTargeted = false

    // Image references (image generation + video edit models' single ref slot)
    @State var imageReferences: [MediaAsset] = []
    @State var imageRefTargeted = false

    // Video reference-to-video
    @State var refImages: [MediaAsset] = []
    @State var refVideos: [MediaAsset] = []
    @State var refAudios: [MediaAsset] = []
    @State var refsTargeted = false

    /// See frames/references mode for `framesAndReferencesExclusive` models.
    @State var framesRefsMode: FramesRefsMode = .firstLast

    // Source video (for video-to-video edit models)
    @State var sourceVideo: MediaAsset?
    @State var sourceVideoTargeted = false
    @State var motionReferenceTargeted = false

    // Source media for audio transformations and video-to-audio models
    @State var audioSource: MediaAsset?
    @State var audioSourceTargeted = false

    // Source media for enhancement models
    @State var upscaleSource: MediaAsset?
    @State var upscaleSourceTargeted = false

    @State var isPopulatingPanel = false
    @State var editFolderId: String?

    // Prompt @-autocomplete for reference tags (Seedance/Kling/Grok reference mode)
    @State var refMentionQuery: String? = nil
    @State var highlightedMentionIndex: Int = 0

    @State var dropError: String? = nil
    @State var dropErrorTask: Task<Void, Never>? = nil

    @AppStorage("generationPromptExtra") private var promptExtra: Double = 0
    @State private var liveExtra: Double?
    @State private var dragStartExtra: Double?
    @State private var measuredPanelHeight: CGFloat = 0
    @State private var measuredPromptHeight: CGFloat = 0

    /// Everything in the panel except the prompt's variable height, recovered
    /// from two frame-consistent measurements so it never depends on the value
    /// we're trying to clamp.
    private var chromeHeight: CGFloat {
        max(0, measuredPanelHeight - measuredPromptHeight)
    }

    /// Largest prompt growth that keeps the panel inside its allotted slot.
    private var maxPromptExtra: Double {
        guard measuredPanelHeight > 0, maxPanelHeight > 0 else { return 0 }
        let available = maxPanelHeight
            - Double(AppTheme.Spacing.sm * 2)
            - Double(chromeHeight)
            - Double(AppTheme.GenerationPanel.promptMinHeight)
        return max(0, available)
    }

    private var promptHeight: CGFloat {
        let extra = min(max(0, liveExtra ?? promptExtra), maxPromptExtra)
        return AppTheme.GenerationPanel.promptMinHeight + CGFloat(extra)
    }

    enum FramesRefsMode: String, CaseIterable {
        case firstLast = "First/Last"
        case reference = "References"
    }

    struct RefTag: Hashable, Identifiable {
        let label: String
        let kindLabel: String
        var id: String { label }
    }

    enum GenerationType: String, CaseIterable {
        case image = "Image"
        case video = "Video"
        case audio = "Audio"
        case upscale = "Upscale"
        var icon: String {
            switch self {
            case .image: "photo"
            case .video: "video"
            case .audio: "waveform"
            case .upscale: "arrow.up.right.square"
            }
        }
        var accentColor: Color {
            Color(clipType.themeColor)
        }
        var clipType: ClipType {
            switch self {
            case .image: .image
            case .video: .video
            case .audio: .audio
            case .upscale: .video
            }
        }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if catalogReady {
                bodyContent
            } else {
                catalogLoadingView
            }
        }
        .onChange(of: upscaleModels.isEmpty) { _, isEmpty in
            if isEmpty && selectedType == .upscale { selectedType = .video }
        }
    }

    private var catalogLoadingView: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            ProgressView()
            Text("Loading models…")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppTheme.GenerationPanel.loadingHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: AppTheme.Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(AppTheme.Opacity.hint),
                    lineWidth: AppTheme.BorderWidth.hairline
                )
                .allowsHitTesting(false)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.bottom, AppTheme.Spacing.sm)
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            // Type tabs (left) · credits · activity · close (right)
            HStack(spacing: AppTheme.Spacing.sm) {
                typeTabs
                Spacer()
                CreditSummaryView(style: .compact)
                ProjectActivityButton()
                Button {
                    editFolderId = nil
                    editor.showGenerationPanel = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                        .hoverHighlight()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AppTheme.Spacing.md)

            VStack(spacing: AppTheme.Spacing.xs) {
                referencesContent
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let dropError {
                    Text(dropError)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(Color.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .transition(.opacity)
                }

                VStack(spacing: 0) {
                    if showsPrompt { promptArea }
                    if selectedType == .audio && audioModel.supportsLyrics {
                        inputDivider
                        secondaryField(
                            placeholder: "Lyrics (optional). [Verse] and [Chorus] tags supported.",
                            text: $lyrics,
                            minHeight: 60, maxHeight: 120
                        )
                    }
                    if selectedType == .audio && audioModel.supportsStyleInstructions {
                        inputDivider
                        secondaryField(
                            placeholder: "Style instructions (optional). e.g., warm and slow, British accent.",
                            text: $styleInstructions,
                            minHeight: 36, maxHeight: 72
                        )
                    }
                    inputToolbar
                }
                .background {
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
                        .fill(AppTheme.Background.raisedColor)
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous))
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.bottom, AppTheme.Spacing.md)
        }
        .padding(.top, AppTheme.Spacing.md)
        .overlay(alignment: .top) { resizeHandle }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredPanelHeight = $0 }
        .background {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: AppTheme.Radius.xl))
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.xl, style: .continuous)
                .strokeBorder(
                    isPromptFocused
                        ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium)
                        : Color.white.opacity(AppTheme.Opacity.hint),
                    lineWidth: isPromptFocused ? AppTheme.BorderWidth.thin : AppTheme.BorderWidth.hairline
                )
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.15), value: isPromptFocused)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.bottom, AppTheme.Spacing.sm)
        .frame(maxHeight: max(0, CGFloat(maxPanelHeight)), alignment: .top)
        .onAppear {
            let hadSeed = editor.pendingPanelSeed != nil
            consumePendingPanelSeed()
            // A seeded edit may reuse a now-disabled model; keep its selection.
            if !hadSeed { normalizeModelSelection() }
        }
        .onChange(of: editor.pendingPanelSeed?.asset.id) { _, _ in consumePendingPanelSeed() }
        .onChange(of: ModelPreferences.shared.disabledIds) { _, _ in
            guard !isPopulatingPanel else { return }
            normalizeModelSelection()
        }
        .onChange(of: account.isPaid) { _, _ in
            guard !isPopulatingPanel else { return }
            normalizeModelSelection()
        }
        .onChange(of: selectedType) { _, newValue in
            guard !isPopulatingPanel else { return }
            normalizeModelSelection()
            resetSettings()
            clearReferences()
            if newValue == .audio { resetAudioState() }
            editFolderId = nil
            editor.clearPendingGenerationPanelState(preservingReplacement: true)
        }
        .onChange(of: selectedVideoModelIndex) { _, _ in
            guard !isPopulatingPanel else { return }
            if selectedType == .video {
                resetSettings()
                if !videoModel.requiresSourceVideo {
                    sourceVideo = nil
                }
                framesRefsMode = .firstLast
                resetRefPools()
            }
        }
        .onChange(of: selectedImageModelIndex) { _, _ in
            guard !isPopulatingPanel else { return }
            if selectedType == .image {
                resetSettings()
            }
        }
        .onChange(of: selectedAudioModelIndex) { _, _ in
            guard !isPopulatingPanel else { return }
            if selectedType == .audio { resetAudioState() }
        }
        .onChange(of: selectedUpscaleModelIndex) { _, _ in
            guard !isPopulatingPanel else { return }
            if selectedType == .upscale { resetUpscaleSettings() }
        }
        .onChange(of: upscaleSource?.id) { _, _ in
            guard selectedType == .upscale, !isPopulatingPanel else { return }
            normalizeModelSelection()
            resetUpscaleSettings()
        }
    }

    @ViewBuilder
    private var referencesContent: some View {
        if selectedType == .upscale {
            upscaleSourceStrip
        } else if selectedType == .video && videoModel.requiresSourceVideo {
            editVideoStrip
        } else if selectedType == .video {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if showsFrameStrip { videoFrameStrip }
                if showsRefSections { videoReferenceSections }
            }
        } else if selectedType == .image && imageModel.supportsImageReference {
            imageReferenceStrip
        } else if selectedType == .audio && audioModel.acceptsSourceMedia {
            audioSourceStrip
        }
    }

    // MARK: - Resize handle

    private var resizeHandle: some View {
        Capsule()
            .fill(Color.white.opacity(AppTheme.Opacity.soft))
            .frame(width: 24, height: 2)
            .frame(maxWidth: .infinity, minHeight: AppTheme.Spacing.md)
            .contentShape(Rectangle())
            .pointerStyle(.rowResize)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartExtra ?? Double(liveExtra ?? promptExtra)
                        dragStartExtra = start
                        let raw = start - Double(value.translation.height)
                        liveExtra = min(max(0, raw), maxPromptExtra)
                    }
                    .onEnded { _ in
                        if let live = liveExtra { promptExtra = live }
                        liveExtra = nil
                        dragStartExtra = nil
                    }
            )
    }

    // MARK: - Prompt area (inside input box)

    private var promptArea: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $prompt)
                .font(.system(size: AppTheme.FontSize.sm))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.automatic)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.top, AppTheme.Spacing.sm)
                .padding(.bottom, AppTheme.Spacing.xs)
                .focused($isPromptFocused)
                .onChange(of: prompt) { _, new in updateRefMentionQuery(from: new) }
                .onKeyPress(phases: [.down, .repeat]) { press in handleMentionKey(press) }
                .popover(isPresented: Binding(
                    get: { showMentionPicker },
                    set: { if !$0 { refMentionQuery = nil } }
                ), attachmentAnchor: .point(.topLeading), arrowEdge: .top) {
                    refMentionPopover
                }

            if prompt.isEmpty {
                Text(promptPlaceholder)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.top, AppTheme.Spacing.md)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: promptHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredPromptHeight = $0 }
    }

    // MARK: - Secondary fields (lyrics / style instructions)

    private var inputDivider: some View {
        Rectangle().fill(Color.white.opacity(AppTheme.Opacity.hint)).frame(height: AppTheme.BorderWidth.hairline)
    }

    private func secondaryField(
        placeholder: String,
        text: Binding<String>,
        minHeight: CGFloat,
        maxHeight: CGFloat
    ) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(size: AppTheme.FontSize.sm))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.automatic)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)

            if text.wrappedValue.isEmpty {
                Text(placeholder)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.top, AppTheme.Spacing.sm)
                    .allowsHitTesting(false)
            }
        }
        .frame(minHeight: minHeight, maxHeight: maxHeight)
    }

    // MARK: - Input toolbar (bottom of input box)

    private var inputToolbar: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            modelPicker
            if showsFramesRefsPicker { framesRefsModePicker }
            if selectedType == .audio, audioModel.voices != nil {
                voicePicker
            }
            if selectedType == .audio, audioModel.targetLanguages != nil {
                languagePicker
            }
            if hasAnySettings { settingsButton }

            Spacer(minLength: AppTheme.Spacing.xs)

            costEstimateLabel
            submitButton
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.sm)
    }
}
