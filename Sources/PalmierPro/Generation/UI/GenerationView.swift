import SwiftUI

struct GenerationView: View {
    let maxPanelHeight: Double

    @Environment(EditorViewModel.self) var editor
    @Bindable private var account = AccountService.shared
    @State private var prompt = ""
    @State private var selectedType: GenerationType = .video
    @State private var selectedVideoModelIndex = 0
    @State private var selectedImageModelIndex = 0
    @State private var selectedAudioModelIndex = 0
    @State private var selectedDuration = 5
    @State private var selectedAspectRatio = "16:9"
    @State private var selectedResolution = "1080p"
    @State private var selectedQuality = "high"
    @State private var selectedNumImages = 1

    // Audio extras
    @State private var selectedVoice = ""
    @State private var lyrics = ""
    @State private var styleInstructions = ""
    @State private var instrumental = false
    @State private var selectedAudioDuration = 30
    @State private var generateAudio = true
    @State private var showSettingsPopover = false
    @FocusState private var isPromptFocused: Bool

    // Video frame references
    @State private var firstFrame: MediaAsset?
    @State private var lastFrame: MediaAsset?
    @State private var firstFrameTargeted = false
    @State private var lastFrameTargeted = false

    // Image references (image generation + video edit models' single ref slot)
    @State private var imageReferences: [MediaAsset] = []
    @State private var imageRefTargeted = false

    // Video reference-to-video
    @State private var refImages: [MediaAsset] = []
    @State private var refVideos: [MediaAsset] = []
    @State private var refAudios: [MediaAsset] = []
    @State private var refsTargeted = false

    /// See frames/references mode for `framesAndReferencesExclusive` models.
    @State private var framesRefsMode: FramesRefsMode = .firstLast

    // Source video (for video-to-video edit models)
    @State private var sourceVideo: MediaAsset?
    @State private var sourceVideoTargeted = false
    @State private var motionReferenceTargeted = false

    // Source video for video-to-audio models (Sonilo, Mirelo)
    @State private var audioVideoSource: MediaAsset?
    @State private var audioVideoTargeted = false

    @State private var isPopulatingPanel = false
    @State private var editFolderId: String?

    // Prompt @-autocomplete for reference tags (Seedance/Kling/Grok reference mode)
    @State private var refMentionQuery: String? = nil
    @State private var highlightedMentionIndex: Int = 0

    @State private var dropError: String? = nil
    @State private var dropErrorTask: Task<Void, Never>? = nil

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
        case reference = "Reference"
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
        var icon: String {
            switch self {
            case .image: "photo"
            case .video: "video"
            case .audio: "waveform"
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
            }
        }
    }

    // MARK: - Computed state

    private var videoModels: [VideoModelConfig] { ModelCatalog.shared.video }
    private var imageModels: [ImageModelConfig] { ModelCatalog.shared.image }
    private var audioModels: [AudioModelConfig] { ModelCatalog.shared.audio }

    private var videoModel: VideoModelConfig { selectedModel(videoModels, at: selectedVideoModelIndex) }
    private var imageModel: ImageModelConfig { selectedModel(imageModels, at: selectedImageModelIndex) }
    private var audioModel: AudioModelConfig { selectedModel(audioModels, at: selectedAudioModelIndex) }

    private var currentModelLocked: Bool {
        guard !account.isPaid else { return false }
        switch selectedType {
        case .video: return videoModel.paidOnly
        case .image: return imageModel.paidOnly
        case .audio: return audioModel.paidOnly
        }
    }

    private func selectedModel<T>(_ models: [T], at index: Int) -> T {
        let safeIndex = models.indices.contains(index) ? index : models.startIndex
        return models[safeIndex]
    }

    private func isAvailable(_ paidOnly: Bool) -> Bool { account.isPaid || !paidOnly }

    private var enabledVideoModels: [(index: Int, model: VideoModelConfig)] {
        videoModels.enumerated()
            .filter { ModelPreferences.shared.isEnabled($0.element.id) && isAvailable($0.element.paidOnly) }
            .map { (index: $0.offset, model: $0.element) }
    }
    private var enabledImageModels: [(index: Int, model: ImageModelConfig)] {
        imageModels.enumerated()
            .filter { ModelPreferences.shared.isEnabled($0.element.id) && isAvailable($0.element.paidOnly) }
            .map { (index: $0.offset, model: $0.element) }
    }
    private var enabledAudioModels: [(index: Int, model: AudioModelConfig)] {
        audioModels.enumerated()
            .filter { ModelPreferences.shared.isEnabled($0.element.id) && isAvailable($0.element.paidOnly) }
            .map { (index: $0.offset, model: $0.element) }
    }
    private var enabledAudioModelsByCategory: [AudioModelConfig.Category: [(index: Int, model: AudioModelConfig)]] {
        var grouped: [AudioModelConfig.Category: [(index: Int, model: AudioModelConfig)]] = [:]
        grouped.reserveCapacity(AudioModelConfig.Category.allCases.count)
        for item in enabledAudioModels {
            grouped[item.model.category, default: []].append(item)
        }
        return grouped
    }

    private func normalizeModelSelection() {
        switch selectedType {
        case .video:
            if !enabledVideoModels.contains(where: { $0.index == selectedVideoModelIndex }) {
                selectedVideoModelIndex = enabledVideoModels.first?.index ?? 0
            }
        case .image:
            if !enabledImageModels.contains(where: { $0.index == selectedImageModelIndex }) {
                selectedImageModelIndex = enabledImageModels.first?.index ?? 0
            }
        case .audio:
            if !enabledAudioModels.contains(where: { $0.index == selectedAudioModelIndex }) {
                selectedAudioModelIndex = enabledAudioModels.first?.index ?? 0
            }
        }
    }

    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespaces) }
    private var isPromptEmpty: Bool { trimmedPrompt.isEmpty }

    private var canSubmit: Bool {
        guard canAffordGeneration else { return false }
        if selectedType == .video && videoModel.requiresSourceVideo {
            guard sourceVideo != nil else { return false }
            if videoModel.requiresReferenceImage && imageReferences.isEmpty { return false }
            if !videoModel.supportsReferences && isPromptEmpty { return false }
            return true
        }
        if selectedType == .video && videoModel.framesAndReferencesExclusive
            && framesRefsMode == .reference && refImages.isEmpty
            && refVideos.isEmpty && refAudios.isEmpty {
            return false
        }
        if selectedType == .audio {
            if audioModel.inputs.contains(.video) {
                return audioVideoSource != nil
            }
            return trimmedPrompt.count >= audioModel.minPromptLength
        }
        return !isPromptEmpty
    }

    private var allRefs: [MediaAsset] { refImages + refVideos + refAudios }
    private var totalRefCount: Int { allRefs.count }

    private var isRefCapReached: Bool {
        if let total = videoModel.maxTotalReferences, totalRefCount >= total { return true }
        let imgFull = videoModel.maxReferenceImages == 0 || refImages.count >= videoModel.maxReferenceImages
        let vidFull = videoModel.maxReferenceVideos == 0 || refVideos.count >= videoModel.maxReferenceVideos
        let audFull = videoModel.maxReferenceAudios == 0 || refAudios.count >= videoModel.maxReferenceAudios
        return imgFull && vidFull && audFull
    }

    private var showsRefSections: Bool {
        guard selectedType == .video, videoModel.supportsReferences else { return false }
        if videoModel.requiresSourceVideo { return false }
        if videoModel.framesAndReferencesExclusive {
            return framesRefsMode == .reference
        }
        return true
    }

    private var showsFrameStrip: Bool {
        guard selectedType == .video, videoModel.supportsFirstFrame else { return false }
        if videoModel.requiresSourceVideo { return false }
        if videoModel.framesAndReferencesExclusive {
            return framesRefsMode == .firstLast
        }
        return true
    }

    private var hasAnySettings: Bool {
        switch selectedType {
        case .video: return !videoModel.durations.isEmpty || !videoModel.aspectRatios.isEmpty || videoModel.resolutions != nil || videoModel.audioDiscountRate != nil
        case .image: return !imageModel.aspectRatios.isEmpty || imageModel.resolutions != nil || imageModel.qualities != nil || imageModel.maxImages > 1
        case .audio: return audioModel.supportsInstrumental || audioModel.durations != nil
        }
    }

    private var currentModelName: String {
        switch selectedType {
        case .video: videoModel.displayName
        case .image: imageModel.displayName
        case .audio: audioModel.displayName
        }
    }

    private var currentModelId: String {
        switch selectedType {
        case .video: videoModel.id
        case .image: imageModel.id
        case .audio: audioModel.id
        }
    }

    private var currentAspectRatios: [String] {
        switch selectedType {
        case .video: videoModel.aspectRatios
        case .image: imageModel.aspectRatios
        case .audio: []
        }
    }

    private var currentResolutions: [String]? {
        switch selectedType {
        case .video: videoModel.resolutions
        case .image: imageModel.resolutions
        case .audio: nil
        }
    }

    private var effectiveResolution: String? {
        currentResolutions != nil ? selectedResolution : nil
    }

    private var currentQualities: [String]? {
        selectedType == .image ? imageModel.qualities : nil
    }

    private var audioPromptHint: String {
        audioModel.minPromptLength > 1 ? " (min \(audioModel.minPromptLength) chars)" : ""
    }

    private var supportsAudioToggle: Bool {
        selectedType == .video && videoModel.audioDiscountRate != nil
    }

    private var effectiveGenerateAudio: Bool {
        supportsAudioToggle ? generateAudio : true
    }

    private var promptPlaceholder: String {
        switch selectedType {
        case .image: "Describe the image"
        case .video: "Describe the video"
        case .audio:
            switch audioModel.category {
            case .tts: "Text to speak\(audioPromptHint)"
            case .music: "Describe the music style or mood\(audioPromptHint)"
            case .sfx: "Describe the sound\(audioPromptHint)"
            }
        }
    }

    private var effectiveVideoSeconds: Int {
        guard videoModel.requiresSourceVideo else { return selectedDuration }
        if let trim = editor.pendingEditTrimmedSource,
           let sv = sourceVideo,
           trim.sourceURL == sv.url, trim.hasTrim {
            return max(1, Int(trim.durationSeconds.rounded()))
        }
        return max(0, Int((sourceVideo?.duration ?? 0).rounded()))
    }

    private var effectiveAudioVideoSpanSeconds: Double {
        guard let source = audioVideoSource else { return 0 }
        if let trim = audioVideoTrimmedSource(for: source), trim.hasTrim {
            return trim.durationSeconds
        }
        return source.duration
    }

    private var effectiveAudioVideoSeconds: Int {
        max(1, Int(effectiveAudioVideoSpanSeconds.rounded()))
    }

    private func audioVideoTrimmedSource(for source: MediaAsset) -> TrimmedSource? {
        guard let trim = editor.pendingEditTrimmedSource, trim.sourceURL == source.url else { return nil }
        return trim
    }

    /// Live credit estimate for the current form state.
    private var estimatedCost: Int? {
        switch selectedType {
        case .video:
            return CostEstimator.videoCost(
                model: videoModel,
                durationSeconds: effectiveVideoSeconds,
                resolution: effectiveResolution,
                generateAudio: effectiveGenerateAudio
            )
        case .image:
            let quality = imageModel.qualities != nil ? selectedQuality : nil
            return CostEstimator.imageCost(
                model: imageModel,
                resolution: effectiveResolution,
                quality: quality,
                numImages: selectedNumImages
            )
        case .audio:
            let duration: Int? = audioModel.inputs.contains(.video)
                ? (audioVideoSource == nil ? nil : effectiveAudioVideoSeconds)
                : (audioModel.durations != nil ? selectedAudioDuration : nil)
            return CostEstimator.audioCost(
                model: audioModel, prompt: trimmedPrompt, durationSeconds: duration
            )
        }
    }

    private var remainingCredits: Int? {
        guard let budget = AccountService.shared.budgetCredits else { return nil }
        return max(0, budget - AccountService.shared.spentCredits)
    }

    private var hasInsufficientCredits: Bool {
        guard let cost = estimatedCost, let left = remainingCredits else { return false }
        return cost > left
    }

    private var canAffordGeneration: Bool {
        guard let left = remainingCredits else { return true }
        if let cost = estimatedCost { return cost <= left }
        return left > 0
    }

    private var costHelpText: String {
        guard let cost = estimatedCost else {
            return "Estimated cost. Actual billing may differ slightly."
        }
        guard let left = remainingCredits else {
            return "\(cost) credits estimated. Actual billing may differ."
        }
        if cost > left {
            return "\(cost) credits needed. Only \(left.formatted()) remaining."
        }
        return "\(cost) credits. \((left - cost).formatted()) credits remaining after this generation."
    }

    private var settingsSummary: String {
        var parts: [String] = []
        if selectedType == .audio {
            if audioModel.durations != nil { parts.append("\(selectedAudioDuration)s") }
            if audioModel.supportsInstrumental && instrumental { parts.append("Instrumental") }
            return parts.isEmpty ? "Settings" : parts.joined(separator: " \u{00B7} ")
        }
        if currentResolutions != nil { parts.append(resolutionLabel(selectedResolution)) }
        if currentQualities != nil { parts.append(selectedQuality) }
        if selectedType == .video { parts.append("\(selectedDuration)s") }
        if !selectedAspectRatio.isEmpty, !currentAspectRatios.isEmpty {
            parts.append(selectedAspectRatio)
        }
        if selectedType == .image, imageModel.maxImages > 1, selectedNumImages > 1 {
            parts.append("×\(selectedNumImages)")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func resolutionLabel(_ id: String) -> String {
        selectedType == .image ? ImageModelConfig.resolutionDisplayLabel(id) : id
    }

    // MARK: - Body

    private var refGridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: AppTheme.GenerationPanel.referenceTileWidth), spacing: AppTheme.Spacing.xs)]
    }

    private var catalogReady: Bool {
        !videoModels.isEmpty
            && !imageModels.isEmpty
            && !audioModels.isEmpty
    }

    var body: some View {
        Group {
            if catalogReady {
                bodyContent
            } else {
                catalogLoadingView
            }
        }
    }

    private var aiAllowed: Bool { account.aiAllowed }

    private var catalogLoadingView: some View {
        VStack(spacing: AppTheme.Spacing.md) {
            ProgressView()
            Text("Loading models…")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .frame(maxWidth: .infinity)
        .frame(height: AppTheme.GenerationPanel.loadingHeight)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .fill(AppTheme.aiGradientDark)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .shadow(AppTheme.Shadow.sm)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.bottom, AppTheme.Spacing.sm)
    }

    private var bodyContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            resizeHandle
            // Type tabs (left) · credits · activity · close (right)
            HStack(spacing: AppTheme.Spacing.sm) {
                typeTabs
                Spacer()
                CreditSummaryView(style: .compact)
                ProjectActivityButton()
                Button {
                    editor.pendingEditReplacementClipId = nil
                    editor.pendingEditTrimmedSource = nil
                    editor.pendingEditAudioPlacement = nil
                    editor.pendingPanelSeed = nil
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
            .padding(.horizontal, AppTheme.Spacing.sm)

            if showsFramesRefsPicker {
                framesRefsModePicker
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppTheme.Spacing.sm)
            }

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
                    promptArea
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
                    let r = AppTheme.Radius.concentric(outer: AppTheme.Radius.lg, padding: AppTheme.Spacing.sm)
                    RoundedRectangle(cornerRadius: r)
                        .fill(Color.black.opacity(AppTheme.Opacity.subtle))
                }
                .overlay {
                    let r = AppTheme.Radius.concentric(outer: AppTheme.Radius.lg, padding: AppTheme.Spacing.sm)
                    RoundedRectangle(cornerRadius: r)
                        .strokeBorder(
                            isPromptFocused ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong) : Color.white.opacity(AppTheme.Opacity.faint),
                            lineWidth: AppTheme.BorderWidth.thin
                        )
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.concentric(outer: AppTheme.Radius.lg, padding: AppTheme.Spacing.sm)))
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.bottom, AppTheme.Spacing.sm)
        }
        .padding(.top, AppTheme.Spacing.xxs)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { measuredPanelHeight = $0 }
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .fill(AppTheme.aiGradientDark)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .strokeBorder(AppTheme.aiGradientDark, lineWidth: AppTheme.BorderWidth.medium)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .shadow(AppTheme.Shadow.sm)
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
            editor.pendingEditTrimmedSource = nil
            editor.pendingEditAudioPlacement = nil
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
    }

    @ViewBuilder
    private var referencesContent: some View {
        if selectedType == .video && videoModel.requiresSourceVideo {
            editVideoStrip
        } else if selectedType == .video {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if showsFrameStrip { videoFrameStrip }
                if showsRefSections { videoReferenceSections }
            }
        } else if selectedType == .image && imageModel.supportsImageReference {
            imageReferenceStrip
        } else if selectedType == .audio && audioModel.inputs.contains(.video) {
            audioVideoStrip
        }
    }

    private var audioVideoStrip: some View {
        frameSlot(
            label: "Source Video",
            asset: audioVideoSource,
            isTargeted: $audioVideoTargeted,
            accepting: [.video],
            iconName: "video.badge.plus",
            onDrop: { audioVideoSource = $0 },
            onClear: { audioVideoSource = nil }
        )
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

    private var refMentionPopover: some View {
        let tags = matchedRefTags
        return VStack(alignment: .leading, spacing: 0) {
            if tags.isEmpty {
                Text("No matches")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .padding(AppTheme.Spacing.md)
            } else {
                ForEach(Array(tags.enumerated()), id: \.element.id) { index, tag in
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text("@\(tag.label)")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text(tag.kindLabel)
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, AppTheme.Spacing.xs)
                    .frame(minWidth: 160, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(index == highlightedMentionIndex ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.moderate) : .clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { pickRefTag(tag) }
                    .onHover { hovering in if hovering { highlightedMentionIndex = index } }
                }
            }
        }
        .padding(AppTheme.Spacing.xs)
        .frame(minWidth: 180)
        .glassEffect(.clear, in: .rect(cornerRadius: AppTheme.Radius.md))
    }

    private func updateRefMentionQuery(from text: String) {
        let newQuery: String? = {
            guard !availableRefTags.isEmpty else { return nil }
            guard let lastAt = text.lastIndex(of: "@") else { return nil }
            let after = text[text.index(after: lastAt)...]
            if after.contains(where: { $0.isWhitespace || $0.isNewline }) { return nil }
            if lastAt > text.startIndex {
                let prev = text[text.index(before: lastAt)]
                if !prev.isWhitespace && !prev.isNewline { return nil }
            }
            return String(after)
        }()
        guard newQuery != refMentionQuery else { return }
        refMentionQuery = newQuery
        highlightedMentionIndex = 0
    }

    private func handleMentionKey(_ press: KeyPress) -> KeyPress.Result {
        guard showMentionPicker else { return .ignored }
        let tags = matchedRefTags
        switch press.key {
        case .upArrow:
            guard !tags.isEmpty else { return .handled }
            highlightedMentionIndex = max(0, highlightedMentionIndex - 1)
            return .handled
        case .downArrow:
            guard !tags.isEmpty else { return .handled }
            highlightedMentionIndex = min(tags.count - 1, highlightedMentionIndex + 1)
            return .handled
        case .return:
            if tags.indices.contains(highlightedMentionIndex) {
                pickRefTag(tags[highlightedMentionIndex])
                return .handled
            }
            return .ignored
        case .escape:
            refMentionQuery = nil
            return .handled
        default:
            return .ignored
        }
    }

    private func pickRefTag(_ tag: RefTag) {
        if let lastAt = prompt.lastIndex(of: "@") {
            let prefix = prompt[..<lastAt]
            prompt = String(prefix) + "@\(tag.label) "
        } else {
            prompt += "@\(tag.label) "
        }
        refMentionQuery = nil
        highlightedMentionIndex = 0
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
        VStack(spacing: 0) {
            inputDivider
            HStack(spacing: AppTheme.Spacing.sm) {
                modelPicker
                if selectedType == .audio, audioModel.voices != nil {
                    voicePicker
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

    private var costEstimateLabel: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "dollarsign.circle.fill")
                .font(.system(size: AppTheme.FontSize.sm))
            Text(estimatedCost.map { $0.formatted() } ?? "—")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .foregroundStyle(hasInsufficientCredits ? .red : AppTheme.Text.secondaryColor)
        .help(costHelpText)
    }

    private var voicePicker: some View {
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
                Text(selectedVoice.isEmpty ? (audioModel.defaultVoice ?? "Voice") : selectedVoice)
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

    // MARK: - Video frame references

    private var videoFrameStrip: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            frameSlot(label: "First Frame", asset: firstFrame, isTargeted: $firstFrameTargeted,
                      onDrop: { firstFrame = $0 }, onClear: { firstFrame = nil })
            if videoModel.supportsLastFrame {
                frameSlot(label: "Last Frame", asset: lastFrame, isTargeted: $lastFrameTargeted,
                          onDrop: { lastFrame = $0 }, onClear: { lastFrame = nil })
            }
        }
    }

    // MARK: - First/Last / Reference mode picker (Seedance, Grok)

    private var framesRefsModePicker: some View {
        HStack(spacing: AppTheme.Spacing.lg) {
            ForEach(FramesRefsMode.allCases, id: \.self) { mode in
                Button {
                    framesRefsMode = mode
                    switch mode {
                    case .firstLast: resetRefPools()
                    case .reference: firstFrame = nil; lastFrame = nil
                    }
                } label: {
                    VStack(spacing: AppTheme.Spacing.xxs) {
                        Text(mode.rawValue)
                            .font(.system(size: AppTheme.FontSize.xs, weight: framesRefsMode == mode ? .semibold : .medium))
                            .foregroundStyle(framesRefsMode == mode
                                ? AppTheme.Text.primaryColor
                                : AppTheme.Text.tertiaryColor)
                            .fixedSize()
                        Rectangle()
                            .fill(framesRefsMode == mode ? AppTheme.Accent.primary : Color.clear)
                            .frame(height: AppTheme.BorderWidth.medium)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .fixedSize()
    }

    // MARK: - Unified video references strip (Seedance/Kling/Grok reference-to-video)

    private var videoReferenceSections: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("References")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(refCounterLabel)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }

            LazyVGrid(
                columns: refGridColumns,
                alignment: .leading,
                spacing: AppTheme.Spacing.xs
            ) {
                ForEach(allRefCardItems, id: \.asset.id) { item in
                    refCard(asset: item.asset, tag: item.tag) {
                        removeRef(item.type, byId: item.asset.id)
                    }
                }
                if !isRefCapReached {
                    dropZone(
                        isTargeted: $refsTargeted,
                        accepting: Set(ClipType.allCases),
                        iconName: "plus"
                    ) { asset in
                        addRefAsset(asset)
                    }
                }
            }
        }
    }

    private var allRefCardItems: [(asset: MediaAsset, tag: String, type: ClipType)] {
        ClipType.allCases.flatMap { type -> [(asset: MediaAsset, tag: String, type: ClipType)] in
            let assets: [MediaAsset]
            switch type {
            case .image: assets = refImages
            case .video: assets = refVideos
            case .audio: assets = refAudios
            case .text, .lottie: assets = []
            }
            let noun = tagNoun(for: type)
            return assets.enumerated().map {
                (asset: $1, tag: "@\(noun)\($0 + 1)", type: type)
            }
        }
    }

    private func refCap(for type: ClipType) -> Int {
        switch type {
        case .image: videoModel.maxReferenceImages
        case .video: videoModel.maxReferenceVideos
        case .audio: videoModel.maxReferenceAudios
        case .text, .lottie: 0
        }
    }

    private func refCount(for type: ClipType) -> Int {
        switch type {
        case .image: refImages.count
        case .video: refVideos.count
        case .audio: refAudios.count
        case .text, .lottie: 0
        }
    }

    /// Tag noun used in `@Image1` / `@Video1` / `@Audio1` / `@Element1` labels.
    private func tagNoun(for type: ClipType) -> String {
        switch type {
        case .image: videoModel.referenceTagNoun
        case .video: "Video"
        case .audio: "Audio"
        case .text: "Text"
        case .lottie: "Lottie"
        }
    }

    private func addRefAsset(_ asset: MediaAsset) {
        let inflight = editor.mediaAssets.filter(\.isGenerating).count
        Log.generation.notice("addRefAsset id=\(asset.id.prefix(8)) type=\(asset.type.rawValue) existing=\(refImages.count)+\(refVideos.count)+\(refAudios.count) inflightGen=\(inflight)")
        if allRefs.contains(where: { $0.id == asset.id }) {
            flashDropError("\(asset.name) is already a reference")
            return
        }
        var selection = videoInputAssets(for: videoModel)
        switch asset.type {
        case .image: selection.imageRefs.append(asset)
        case .video: selection.videoRefs.append(asset)
        case .audio: selection.audioRefs.append(asset)
        case .text, .lottie:
            let supported = ClipType.allCases.filter { refCap(for: $0) > 0 }.map(\.rawValue).joined(separator: " and ")
            flashDropError("\(videoModel.displayName) only accepts \(supported) references.")
            return
        }
        if let err = selection.validate(for: videoModel) {
            flashDropError(err)
            return
        }
        switch asset.type {
        case .image: refImages.append(asset)
        case .video: refVideos.append(asset)
        case .audio: refAudios.append(asset)
        case .text, .lottie: break
        }
    }

    private func validatedDropZone(
        isTargeted: Binding<Bool>,
        expects: Set<ClipType>,
        iconName: String,
        onDrop: @escaping (MediaAsset) -> Void
    ) -> some View {
        dropZone(
            isTargeted: isTargeted,
            accepting: Set(ClipType.allCases),
            iconName: iconName
        ) { asset in
            if expects.contains(asset.type) {
                onDrop(asset)
            } else {
                let kinds = expects.map(\.rawValue).sorted().joined(separator: " or ")
                flashDropError("Drop \(kinds) here.")
            }
        }
    }

    private func flashDropError(_ message: String) {
        dropErrorTask?.cancel()
        dropError = message
        dropErrorTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { dropError = nil }
        }
    }

    private func removeRef(_ type: ClipType, byId id: MediaAsset.ID) {
        switch type {
        case .image: refImages.removeAll { $0.id == id }
        case .video: refVideos.removeAll { $0.id == id }
        case .audio: refAudios.removeAll { $0.id == id }
        case .text, .lottie: break
        }
    }

    private func resetRefPools() {
        refImages.removeAll()
        refVideos.removeAll()
        refAudios.removeAll()
    }

    private var refCounterLabel: String {
        let total = totalRefCount
        if let cap = videoModel.maxTotalReferences {
            let shortLabel: (ClipType) -> String = { switch $0 { case .image: "img"; case .video: "vid"; case .audio: "aud"; case .text: "txt"; case .lottie: "lot" } }
            let parts = ClipType.allCases
                .filter { refCap(for: $0) > 0 }
                .map { "\(refCount(for: $0)) \(shortLabel($0))" }
            return "\(total)/\(cap) · \(parts.joined(separator: " · "))"
        }
        let singleCap = ClipType.allCases.map(refCap(for:)).max() ?? 0
        return "\(total)/\(singleCap)"
    }

    private var availableRefTags: [RefTag] {
        guard showsRefSections else { return [] }
        return ClipType.allCases.flatMap { type -> [RefTag] in
            let noun = tagNoun(for: type)
            return (0..<refCount(for: type)).map { i in
                RefTag(label: "\(noun)\(i + 1)", kindLabel: type.rawValue)
            }
        }
    }

    private var matchedRefTags: [RefTag] {
        let q = (refMentionQuery ?? "").lowercased()
        if q.isEmpty { return availableRefTags }
        return availableRefTags.filter { $0.label.lowercased().contains(q) }
    }

    private var showMentionPicker: Bool {
        refMentionQuery != nil && !availableRefTags.isEmpty
    }

    private func frameSlot(
        label: String, asset: MediaAsset?,
        isTargeted: Binding<Bool>,
        accepting acceptedTypes: Set<ClipType> = [.image],
        iconName: String = "photo.badge.plus",
        onDrop: @escaping (MediaAsset) -> Void,
        onClear: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            if let asset {
                Group {
                    if let thumb = asset.thumbnail {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: AppTheme.GenerationPanel.referenceTileWidth, height: AppTheme.GenerationPanel.referenceTileHeight)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin))
                .overlay(alignment: .topTrailing) {
                    Button { onClear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: AppTheme.FontSize.smMd))
                            .foregroundStyle(.white.opacity(AppTheme.Opacity.prominent))
                            .shadow(radius: 2)
                            .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                validatedDropZone(
                    isTargeted: isTargeted,
                    expects: acceptedTypes,
                    iconName: iconName,
                    onDrop: onDrop
                )
            }
        }
    }

    // MARK: - Image references

    private var imageReferenceStrip: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("References")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            LazyVGrid(
                columns: refGridColumns,
                alignment: .leading,
                spacing: AppTheme.Spacing.xs
            ) {
                ForEach(imageReferences) { asset in
                    refCard(asset: asset) {
                        imageReferences.removeAll { $0.id == asset.id }
                    }
                }
                validatedDropZone(
                    isTargeted: $imageRefTargeted,
                    expects: [.image],
                    iconName: "photo.badge.plus"
                ) { asset in
                    if imageReferences.contains(where: { $0.id == asset.id }) {
                        flashDropError("\(asset.name) is already a reference")
                    } else {
                        imageReferences.append(asset)
                    }
                }
            }
        }
    }

    private func refCard(asset: MediaAsset, tag: String? = nil, onRemove: @escaping () -> Void) -> some View {
        Group {
            if let thumb = asset.thumbnail {
                Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: asset.type.sfSymbolName)
                        .font(.system(size: AppTheme.FontSize.mdLg))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
        }
        .frame(width: AppTheme.GenerationPanel.referenceTileWidth, height: AppTheme.GenerationPanel.referenceTileHeight)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin))
        .overlay(alignment: .bottomLeading) {
            if let tag {
                Text(tag)
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, AppTheme.Spacing.xs)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .background(Color.black.opacity(AppTheme.Opacity.strong), in: Capsule())
                    .padding(AppTheme.Spacing.xs)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { onRemove() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(.white.opacity(AppTheme.Opacity.prominent))
                    .shadow(radius: 2)
                    .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Edit (video-to-video) strip

    private var editVideoStrip: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            frameSlot(
                label: "Source Video",
                asset: sourceVideo,
                isTargeted: $sourceVideoTargeted,
                accepting: [.video],
                iconName: "video.badge.plus",
                onDrop: { sourceVideo = $0 },
                onClear: { sourceVideo = nil }
            )
            if videoModel.supportsReferences {
                frameSlot(
                    label: "Reference Image",
                    asset: imageReferences.first,
                    isTargeted: $motionReferenceTargeted,
                    accepting: [.image],
                    iconName: "photo.badge.plus",
                    onDrop: { imageReferences = [$0] },
                    onClear: { imageReferences.removeAll() }
                )
            }
        }
    }

    // MARK: - Shared drop zone

    private func dropZone(
        isTargeted: Binding<Bool>,
        accepting acceptedTypes: Set<ClipType> = [.image],
        iconName: String = "photo.badge.plus",
        onDrop: @escaping (MediaAsset) -> Void
    ) -> some View {
        Image(systemName: iconName)
            .font(.system(size: AppTheme.FontSize.smMd))
            .foregroundStyle(isTargeted.wrappedValue ? AppTheme.Accent.primary : AppTheme.Text.mutedColor)
            .frame(width: AppTheme.GenerationPanel.referenceTileWidth, height: AppTheme.GenerationPanel.referenceTileHeight)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(isTargeted.wrappedValue ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint) : Color.white.opacity(AppTheme.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        isTargeted.wrappedValue ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong) : AppTheme.Border.primaryColor,
                        style: StrokeStyle(lineWidth: AppTheme.BorderWidth.thin, dash: [4, 3])
                    )
            )
            .overlay {
                DropTargetOverlay(isTargeted: isTargeted) { payload in
                    for asset in editor.assetsFromDragPayload(payload)
                    where acceptedTypes.contains(asset.type) {
                        onDrop(asset)
                    }
                }
            }
    }

    // MARK: - Submit button

    private var submitButton: some View {
        Button {
            if aiAllowed { submitGeneration() }
            else if !account.isMisconfigured { Task { await account.signInWithGoogle() } }
        } label: {
            Image(systemName: aiAllowed ? "arrow.up" : "person.crop.circle")
                .font(.system(size: AppTheme.FontSize.sm, weight: .bold))
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .controlSize(.regular)
        .tint(AppTheme.Accent.primary)
        .disabled(aiAllowed ? !canSubmit : account.isMisconfigured || account.isSigningIn)
        .opacity((aiAllowed ? canSubmit : !account.isMisconfigured && !account.isSigningIn) ? AppTheme.Opacity.opaque : AppTheme.Opacity.strong)
        .help(aiAllowed ? "" : (account.isMisconfigured ? "AI is unavailable" : account.isSigningIn ? "Opening Google" : "Sign in to generate"))
    }

    // MARK: - Type picker

    private var showsFramesRefsPicker: Bool {
        selectedType == .video && videoModel.framesAndReferencesExclusive
    }

    private var typeTabs: some View {
        HStack(spacing: 0) {
            ForEach(GenerationType.allCases, id: \.self) { type in
                Button {
                    withAnimation(.easeInOut(duration: AppTheme.Anim.hover)) { selectedType = type }
                } label: {
                    Image(systemName: type.icon)
                        .font(.system(size: AppTheme.FontSize.smMd, weight: selectedType == type ? .semibold : .medium))
                        .foregroundStyle(selectedType == type ? type.accentColor : AppTheme.Text.tertiaryColor)
                        .frame(width: AppTheme.IconSize.xl + AppTheme.Spacing.lg, height: AppTheme.IconSize.md)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.concentric(outer: AppTheme.Radius.sm, padding: AppTheme.Spacing.xxs))
                            .fill(selectedType == type ? Color.white.opacity(AppTheme.Opacity.faint) : .clear)
                    )
                    .hoverHighlight(cornerRadius: AppTheme.Radius.concentric(outer: AppTheme.Radius.sm, padding: AppTheme.Spacing.xxs))
                }
                .buttonStyle(.plain)
                .help(type.rawValue)
                .accessibilityLabel(type.rawValue)
            }
        }
        .padding(AppTheme.Spacing.xxs)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    // MARK: - Model picker

    private var modelPicker: some View {
        Menu {
            switch selectedType {
            case .video:
                ForEach(enabledVideoModels, id: \.index) { item in
                    Button(item.model.displayName) { selectedVideoModelIndex = item.index }
                }
            case .image:
                ForEach(enabledImageModels, id: \.index) { item in
                    Button(item.model.displayName) { selectedImageModelIndex = item.index }
                }
            case .audio:
                ForEach(AudioModelConfig.Category.allCases, id: \.self) { category in
                    if let items = enabledAudioModelsByCategory[category], !items.isEmpty {
                        Section(category.label) {
                            ForEach(items, id: \.index) { item in
                                Button(item.model.displayName) { selectedAudioModelIndex = item.index }
                            }
                        }
                    }
                }
            }
            Divider()
            Button {
                SettingsWindowController.shared.show(tab: .models)
            } label: {
                Label("Add models…", systemImage: "plus")
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
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

    // MARK: - Settings

    private var settingsButton: some View {
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

    private var settingsPopoverContent: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            if selectedType == .video {
                settingsPicker("Duration", selection: $selectedDuration, options: videoModel.durations) { "\($0)s" }
            }
            if selectedType == .audio, let durations = audioModel.durations {
                settingsPicker("Duration", selection: $selectedAudioDuration, options: durations) { "\($0)s" }
            }
            if !currentAspectRatios.isEmpty {
                settingsPicker("Aspect Ratio", selection: $selectedAspectRatio, options: currentAspectRatios) { $0 }
            }
            if let resolutions = currentResolutions {
                settingsPicker("Resolution", selection: $selectedResolution, options: resolutions) { resolutionLabel($0) }
            }
            if let qualities = currentQualities {
                settingsPicker("Quality", selection: $selectedQuality, options: qualities) { $0.capitalized }
            }
            if selectedType == .image, imageModel.maxImages > 1 {
                settingsPicker(
                    "Count",
                    selection: $selectedNumImages,
                    options: Array(1...imageModel.maxImages)
                ) { "\($0)" }
            }
            if selectedType == .audio && audioModel.supportsInstrumental {
                Toggle("Instrumental", isOn: $instrumental)
                    .controlSize(.small)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            if selectedType == .video, videoModel.audioDiscountRate != nil {
                let discount = videoModel.audioDiscount(for: effectiveResolution)
                let savings = discount.map { Int(((1 - $0) * 100).rounded()) }
                Toggle("Generate audio", isOn: $generateAudio)
                    .controlSize(.small)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .help(savings.map { "Turn off to save \($0)% on generation cost." } ?? "Turn off to skip audio generation.")
            }
        }
        .padding(AppTheme.Spacing.lg)
        .frame(width: 220)
    }

    private func settingsPicker<T: Hashable>(_ label: String, selection: Binding<T>, options: [T], format: @escaping (T) -> String) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            if options.count <= 5 {
                Picker("", selection: selection) {
                    ForEach(options, id: \.self) { Text(format($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
            } else {
                let cols = options.count == 6 ? 3 : 5
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: cols), spacing: 4) {
                    ForEach(options, id: \.self) { option in
                        Button {
                            selection.wrappedValue = option
                        } label: {
                            Text(format(option))
                                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                                .foregroundStyle(selection.wrappedValue == option ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                                        .fill(selection.wrappedValue == option ? Color.white.opacity(AppTheme.Opacity.soft) : Color.white.opacity(AppTheme.Opacity.subtle))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func videoInputAssets(for model: VideoModelConfig) -> VideoGenerationSubmission.InputAssets {
        if model.requiresSourceVideo {
            return VideoGenerationSubmission.InputAssets(
                sourceVideo: sourceVideo,
                imageRefs: model.supportsReferences ? Array(imageReferences.prefix(1)) : []
            )
        }

        var frames: [MediaAsset] = []
        if showsFrameStrip {
            if let firstFrame { frames.append(firstFrame) }
            if let lastFrame { frames.append(lastFrame) }
        }
        return VideoGenerationSubmission.InputAssets(
            frames: frames,
            imageRefs: showsRefSections ? refImages : [],
            videoRefs: showsRefSections ? refVideos : [],
            audioRefs: showsRefSections ? refAudios : []
        )
    }

    private func preflightValidation(audioDuration: Int) -> String? {
        switch selectedType {
        case .video:
            let inputAssets = videoInputAssets(for: videoModel)
            let modelError: String?
            if videoModel.requiresSourceVideo {
                modelError = videoModel.validate(duration: 0, aspectRatio: "", resolution: nil)
            } else {
                modelError = videoModel.validate(
                    duration: selectedDuration,
                    aspectRatio: selectedAspectRatio,
                    resolution: effectiveResolution
                )
            }
            return modelError ?? inputAssets.validate(for: videoModel)
        case .image:
            let quality = imageModel.qualities != nil ? selectedQuality : nil
            let imageCount = imageModel.maxImages > 1
                ? min(imageModel.maxImages, max(1, selectedNumImages)) : 1
            return imageModel.validate(
                aspectRatio: selectedAspectRatio,
                resolution: effectiveResolution,
                quality: quality,
                imageRefCount: imageReferences.count,
                numImages: imageCount
            )
        case .audio:
            if audioModel.inputs.contains(.video) {
                guard audioVideoSource != nil else { return "Drop a video to score." }
                return audioModel.validate(spanSeconds: effectiveAudioVideoSpanSeconds)
            }
            return audioModel.validate(params: audioParams(audioDuration: audioDuration))
        }
    }

    private func audioParams(audioDuration: Int, videoURL: String? = nil) -> AudioGenerationParams {
        AudioGenerationParams(
            prompt: prompt,
            voice: audioModel.voices != nil && !selectedVoice.isEmpty ? selectedVoice : nil,
            lyrics: audioModel.supportsLyrics && !lyrics.isEmpty ? lyrics : nil,
            styleInstructions: audioModel.supportsStyleInstructions && !styleInstructions.isEmpty
                ? styleInstructions : nil,
            instrumental: audioModel.supportsInstrumental ? instrumental : false,
            durationSeconds: (audioModel.durations != nil || audioModel.inputs.contains(.video)) ? audioDuration : nil,
            videoURL: videoURL
        )
    }

    private func submitGeneration() {
        if currentModelLocked {
            SettingsWindowController.shared.show(tab: .account)
            return
        }
        let audioDuration: Int = {
            guard selectedType == .audio else { return 0 }
            if audioModel.inputs.contains(.video) { return effectiveAudioVideoSeconds }
            return audioModel.durations != nil ? selectedAudioDuration : 0
        }()
        if let err = preflightValidation(audioDuration: audioDuration) {
            flashDropError(err)
            return
        }
        var genInput = GenerationInput(
            prompt: prompt,
            model: currentModelId,
            duration: selectedType == .video ? effectiveVideoSeconds : audioDuration,
            aspectRatio: selectedAspectRatio,
            resolution: effectiveResolution,
            quality: selectedType == .image && imageModel.qualities != nil ? selectedQuality : nil,
            voice: selectedType == .audio && audioModel.voices != nil && !selectedVoice.isEmpty
                ? selectedVoice : nil,
            lyrics: selectedType == .audio && audioModel.supportsLyrics && !lyrics.isEmpty
                ? lyrics : nil,
            styleInstructions: selectedType == .audio && audioModel.supportsStyleInstructions && !styleInstructions.isEmpty
                ? styleInstructions : nil,
            instrumental: selectedType == .audio && audioModel.supportsInstrumental
                ? instrumental : nil,
            generateAudio: supportsAudioToggle ? generateAudio : nil
        )
        let imageCount: Int = {
            guard selectedType == .image, imageModel.maxImages > 1 else { return 1 }
            return min(imageModel.maxImages, max(1, selectedNumImages))
        }()
        if imageCount > 1 {
            genInput.numImages = imageCount
        }

        let replacementClipId = editor.pendingEditReplacementClipId
        editor.pendingEditReplacementClipId = nil
        let pendingAudioPlacement = selectedType == .audio ? editor.pendingEditAudioPlacement : nil
        editor.pendingEditAudioPlacement = nil
        let editorRef = editor
        if let clipId = replacementClipId {
            editor.markPendingReplacement(clipId: clipId)
        }
        let makeOnComplete: (Bool) -> (@MainActor (MediaAsset) -> Void)? = { resetTrim in
            guard let clipId = replacementClipId else { return nil }
            let firstOnly = FirstOnlyFlag()
            return { [weak editorRef] newAsset in
                guard firstOnly.fire() else { return }
                editorRef?.replaceClipMediaRef(clipId: clipId, newAssetId: newAsset.id, resetTrim: resetTrim)
                editorRef?.clearPendingReplacement(clipId: clipId)
            }
        }
        let onFailure: (@MainActor () -> Void)? = {
            guard let clipId = replacementClipId else { return nil }
            return { [weak editorRef] in
                editorRef?.clearPendingReplacement(clipId: clipId)
            }
        }()

        let autoOpenPreview: (String) -> Void = { newAssetId in
            guard replacementClipId == nil else { return }
            editorRef.selectMediaPanelItem(newAssetId)
        }

        switch selectedType {
        case .video:
            let model = videoModel
            let inputAssets = videoInputAssets(for: model)
            let trimmedSource: TrimmedSource? = {
                guard model.requiresSourceVideo,
                      let trim = editor.pendingEditTrimmedSource,
                      let sv = sourceVideo,
                      trim.sourceURL == sv.url else { return nil }
                return trim
            }()
            editor.pendingEditTrimmedSource = nil
            let placeholderDuration: Double
            if model.requiresSourceVideo {
                if let trim = trimmedSource, trim.hasTrim {
                    placeholderDuration = trim.durationSeconds
                } else {
                    placeholderDuration = sourceVideo?.duration ?? 5
                }
            } else {
                placeholderDuration = Double(selectedDuration)
            }
            let videoFolderId: String? = editFolderId ?? (
                model.requiresSourceVideo
                    ? (inputAssets.sourceVideo?.folderId ?? inputAssets.imageRefs.last?.folderId)
                    : inputAssets.textToVideoReferences.last?.folderId
            ) ?? editor.mediaPanelCurrentFolderId
            let videoAssetId = VideoGenerationSubmission.make(
                genInput: genInput,
                model: model,
                inputAssets: inputAssets,
                placeholderDuration: placeholderDuration,
                trimmedSourceOverride: trimmedSource,
                folderId: videoFolderId,
                generateAudio: effectiveGenerateAudio
            ).submit(
                service: editor.generationService,
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: makeOnComplete(trimmedSource?.hasTrim == true),
                onFailure: onFailure
            )
            autoOpenPreview(videoAssetId)
        case .image:
            let model = imageModel
            let imageAssetId = ImageGenerationSubmission.make(
                genInput: genInput,
                model: model,
                references: imageReferences,
                numImages: imageCount,
                folderId: editFolderId ?? imageReferences.last?.folderId ?? editor.mediaPanelCurrentFolderId
            ).submit(
                service: editor.generationService,
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: makeOnComplete(false),
                onFailure: onFailure
            )
            autoOpenPreview(imageAssetId)
        case .audio:
            let model = audioModel
            let onCompleteAudio = makeOnComplete(false)
            if model.inputs.contains(.video), let asset = audioVideoSource {
                let folderId = editFolderId ?? asset.folderId ?? editor.mediaPanelCurrentFolderId
                let trimmedSource = audioVideoTrimmedSource(for: asset)
                let params = audioParams(audioDuration: audioDuration)
                genInput.referenceVideoAssetIds = [asset.id]
                let audioOnComplete: (@MainActor (MediaAsset) -> Void)? = {
                    guard pendingAudioPlacement != nil else { return onCompleteAudio }
                    return { [weak editorRef] asset in
                        editorRef?.finalizeGeneratingClip(placeholderId: asset.id, asset: asset)
                        onCompleteAudio?(asset)
                    }
                }()
                let audioAssetId = AudioGenerationSubmission.make(
                    genInput: genInput,
                    model: model,
                    params: params,
                    folderId: folderId,
                    references: [asset],
                    trimmedSourceOverride: trimmedSource
                ).submit(
                    service: editor.generationService,
                    projectURL: editor.projectURL,
                    editor: editor,
                    onComplete: audioOnComplete,
                    onFailure: onFailure
                )
                if let placement = pendingAudioPlacement {
                    editor.placeGeneratingAudioClip(
                        placeholderId: audioAssetId,
                        startFrame: placement.startFrame,
                        spanSeconds: placement.spanSeconds,
                        actionName: placement.actionName
                    )
                }
            } else {
                let params = audioParams(audioDuration: audioDuration)
                AudioGenerationSubmission.make(
                    genInput: genInput,
                    model: model,
                    params: params,
                    folderId: editFolderId ?? editor.mediaPanelCurrentFolderId
                ).submit(
                    service: editor.generationService,
                    projectURL: editor.projectURL,
                    editor: editor,
                    onComplete: onCompleteAudio,
                    onFailure: onFailure
                )
            }
        }
        editor.pendingEditTrimmedSource = nil
        lyrics = ""
        styleInstructions = ""
        prompt = ""
        editFolderId = nil
        clearReferences()
    }

    private func clearReferences() {
        firstFrame = nil
        lastFrame = nil
        imageReferences.removeAll()
        resetRefPools()
        sourceVideo = nil
        audioVideoSource = nil
    }

    private func consumePendingPanelSeed() {
        guard let seed = editor.pendingPanelSeed else { return }
        populatePanel(asset: seed.asset, stored: seed.stored)
        editor.pendingPanelSeed = nil
    }

    private func populatePanel(asset: MediaAsset, stored: GenerationInput) {
        switch ModelRegistry.byId[stored.model] {
        case .video:
            guard let idx = videoModels.firstIndex(where: { $0.id == stored.model }) else { return }
            isPopulatingPanel = true
            selectedType = .video
            selectedVideoModelIndex = idx
        case .image:
            guard let idx = imageModels.firstIndex(where: { $0.id == stored.model }) else { return }
            isPopulatingPanel = true
            selectedType = .image
            selectedImageModelIndex = idx
        case .audio:
            guard let idx = audioModels.firstIndex(where: { $0.id == stored.model }) else { return }
            isPopulatingPanel = true
            selectedType = .audio
            selectedAudioModelIndex = idx
        case .upscale, .none:
            return
        }
        defer { DispatchQueue.main.async { isPopulatingPanel = false } }

        prompt = stored.prompt
        if !stored.aspectRatio.isEmpty { selectedAspectRatio = stored.aspectRatio }
        if let r = stored.resolution { selectedResolution = r }
        if let q = stored.quality { selectedQuality = q }
        if stored.duration > 0 {
            selectedDuration = stored.duration
            selectedAudioDuration = stored.duration
        }
        if let n = stored.numImages { selectedNumImages = max(1, n) }
        if let v = stored.voice, !v.isEmpty { selectedVoice = v }
        lyrics = stored.lyrics ?? ""
        styleInstructions = stored.styleInstructions ?? ""
        instrumental = stored.instrumental ?? false
        generateAudio = stored.generateAudio ?? true

        clearReferences()

        let assetsById = Dictionary(editor.mediaAssets.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let lookup: (String) -> MediaAsset? = { assetsById[$0] }
        let primary = (stored.imageURLAssetIds ?? []).compactMap(lookup)

        switch selectedType {
        case .video:
            if videoModel.requiresSourceVideo {
                sourceVideo = primary.first
                if videoModel.supportsReferences, primary.count > 1 {
                    imageReferences = [primary[1]]
                }
            } else {
                if videoModel.supportsFirstFrame {
                    firstFrame = primary.first
                    if videoModel.supportsLastFrame, primary.count > 1 {
                        lastFrame = primary[1]
                    }
                }
                refImages = (stored.referenceImageAssetIds ?? []).compactMap(lookup)
                refVideos = (stored.referenceVideoAssetIds ?? []).compactMap(lookup)
                refAudios = (stored.referenceAudioAssetIds ?? []).compactMap(lookup)
                if videoModel.framesAndReferencesExclusive {
                    framesRefsMode = (!refImages.isEmpty || !refVideos.isEmpty || !refAudios.isEmpty)
                        ? .reference : .firstLast
                } else {
                    framesRefsMode = .firstLast
                }
            }
        case .image:
            imageReferences = primary
        case .audio:
            audioVideoSource = (stored.referenceVideoAssetIds ?? []).compactMap(lookup).first
        }

        editFolderId = asset.folderId

        resetSettings()
    }

    private func resetAudioState() {
        let model = audioModel
        selectedVoice = model.defaultVoice ?? ""
        if !model.supportsLyrics { lyrics = "" }
        if !model.supportsStyleInstructions { styleInstructions = "" }
        if !model.supportsInstrumental { instrumental = false }
        if let durations = model.durations, !durations.contains(selectedAudioDuration) {
            selectedAudioDuration = durations.first ?? 30
        }
    }

    private func resetSettings() {
        if !currentAspectRatios.contains(selectedAspectRatio) {
            selectedAspectRatio = currentAspectRatios.first ?? "16:9"
        }
        if let resolutions = currentResolutions, !resolutions.contains(selectedResolution) {
            selectedResolution = resolutions.first ?? "1080p"
        }
        if let qualities = currentQualities, !qualities.contains(selectedQuality) {
            selectedQuality = qualities.last ?? "high"
        }
        if selectedType == .video, !videoModel.durations.contains(selectedDuration) {
            selectedDuration = videoModel.durations.first ?? 5
        }
        if selectedType == .video { generateAudio = true }
        if selectedType == .image {
            selectedNumImages = min(max(1, selectedNumImages), imageModel.maxImages)
        }
    }
}
