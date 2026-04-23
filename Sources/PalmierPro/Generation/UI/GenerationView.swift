import SwiftUI

struct GenerationView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var prompt = ""
    @State private var assetName = ""
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

    @State private var isConsumingEditSource = false

    // Prompt @-autocomplete for reference tags (Seedance/Kling/Grok reference mode)
    @State private var refMentionQuery: String? = nil
    @State private var highlightedMentionIndex: Int = 0

    @State private var dropError: String? = nil
    @State private var dropErrorTask: Task<Void, Never>? = nil

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
            switch self {
            case .image: .purple
            case .video: .blue
            case .audio: .green
            }
        }
    }

    // MARK: - Computed state

    private var videoModel: VideoModelConfig { VideoModelConfig.allModels[selectedVideoModelIndex] }
    private var imageModel: ImageModelConfig { ImageModelConfig.allModels[selectedImageModelIndex] }
    private var audioModel: AudioModelConfig { AudioModelConfig.allModels[selectedAudioModelIndex] }
    private var trimmedPrompt: String { prompt.trimmingCharacters(in: .whitespaces) }
    private var isPromptEmpty: Bool { trimmedPrompt.isEmpty }

    private var canSubmit: Bool {
        guard editor.generationService.hasApiKey else { return false }
        if selectedType == .video && videoModel.requiresSourceVideo {
            guard sourceVideo != nil else { return false }
            if videoModel.supportsReferences && imageReferences.isEmpty { return false }
            if !videoModel.supportsReferences && isPromptEmpty { return false }
            return true
        }
        if selectedType == .video && videoModel.framesAndReferencesExclusive
            && framesRefsMode == .reference && refImages.isEmpty
            && refVideos.isEmpty && refAudios.isEmpty {
            return false
        }
        if selectedType == .audio {
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
        case .image: "Describe the image..."
        case .video: "Describe the video..."
        case .audio:
            switch audioModel.category {
            case .tts: "Text to speak\(audioPromptHint)..."
            case .music: "Describe the music style or mood\(audioPromptHint)..."
            }
        }
    }

    /// Live USD estimate for the current form state
    private var estimatedCost: Double? {
        switch selectedType {
        case .video:
            let seconds = videoModel.requiresSourceVideo
                ? Int((sourceVideo?.duration ?? 0).rounded())
                : selectedDuration
            return CostEstimator.videoCost(
                model: videoModel,
                durationSeconds: seconds,
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
            let duration = audioModel.durations != nil ? selectedAudioDuration : nil
            return CostEstimator.audioCost(
                model: audioModel, prompt: trimmedPrompt, durationSeconds: duration
            )
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            // Type tabs (left) · API key + close (right)
            HStack(spacing: AppTheme.Spacing.sm) {
                typeTabs
                Spacer()
                apiKeyButton
                Button {
                    editor.pendingEditReplacementClipId = nil
                    editor.pendingEditTrimmedSource = nil
                    editor.showGenerationPanel = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(width: 22, height: 22)
                        .hoverHighlight()
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)

            // Frame/image references
            if selectedType == .video && videoModel.requiresSourceVideo {
                editVideoStrip
                    .padding(.horizontal, AppTheme.Spacing.md)
            } else if selectedType == .video {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    if videoModel.framesAndReferencesExclusive {
                        framesRefsModePicker
                    }
                    if showsFrameStrip { videoFrameStrip }
                    if showsRefSections { videoReferenceSections }
                }
                .padding(.horizontal, AppTheme.Spacing.md)
            } else if selectedType == .image && imageModel.supportsImageReference {
                imageReferenceStrip
                    .padding(.horizontal, AppTheme.Spacing.md)
            }

            if let dropError {
                Text(dropError)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .transition(.opacity)
            }

            // Name field
            nameField
                .frame(width: 160, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppTheme.Spacing.sm)

            // Unified input box
            VStack(spacing: 0) {
                promptArea
                if selectedType == .audio && audioModel.supportsLyrics {
                    inputDivider
                    secondaryField(
                        placeholder: "Lyrics (optional) — [Verse], [Chorus] tags supported",
                        text: $lyrics,
                        minHeight: 60, maxHeight: 120
                    )
                }
                if selectedType == .audio && audioModel.supportsStyleInstructions {
                    inputDivider
                    secondaryField(
                        placeholder: "Style instructions (optional) — e.g. warm and slow, British accent",
                        text: $styleInstructions,
                        minHeight: 36, maxHeight: 72
                    )
                }
                inputToolbar
            }
            .background {
                let r = AppTheme.Radius.concentric(outer: AppTheme.Radius.lg, padding: AppTheme.Spacing.sm)
                RoundedRectangle(cornerRadius: r)
                    .fill(Color.white.opacity(0.03))
            }
            .overlay {
                let r = AppTheme.Radius.concentric(outer: AppTheme.Radius.lg, padding: AppTheme.Spacing.sm)
                RoundedRectangle(cornerRadius: r)
                    .strokeBorder(
                        isPromptFocused ? Color.accentColor.opacity(0.5) : Color.white.opacity(0.10),
                        lineWidth: 1
                    )
            }
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.concentric(outer: AppTheme.Radius.lg, padding: AppTheme.Spacing.sm)))
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.bottom, AppTheme.Spacing.sm)
        }
        .padding(.top, AppTheme.Spacing.sm)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                    .fill(.clear)
                    .glassEffect(.regular, in: .rect(cornerRadius: AppTheme.Radius.lg))
            }
            .allowsHitTesting(false)
        }
        .padding(AppTheme.Spacing.sm)
        .onAppear { consumePendingEditSource() }
        .onChange(of: editor.pendingEditSource?.id) { _, _ in consumePendingEditSource() }
        .onChange(of: selectedType) { _, newValue in
            guard !isConsumingEditSource else { return }
            resetSettings()
            clearReferences()
            if newValue == .audio { resetAudioState() }
        }
        .onChange(of: selectedVideoModelIndex) { _, _ in
            guard !isConsumingEditSource else { return }
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
            guard !isConsumingEditSource else { return }
            if selectedType == .image {
                resetSettings()
            }
        }
        .onChange(of: selectedAudioModelIndex) { _, _ in
            guard !isConsumingEditSource else { return }
            if selectedType == .audio { resetAudioState() }
        }
    }

    // MARK: - Name field

    private var nameField: some View {
        TextField("Name (Optional)", text: $assetName)
            .font(.system(size: AppTheme.FontSize.xs))
            .textFieldStyle(.plain)
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs + 1)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.white.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
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
        .frame(minHeight: 70, maxHeight: 120)
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
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, 4)
                    .frame(minWidth: 160, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                            .fill(index == highlightedMentionIndex ? Color.accentColor.opacity(0.22) : .clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { pickRefTag(tag) }
                    .onHover { hovering in if hovering { highlightedMentionIndex = index } }
                }
            }
        }
        .padding(4)
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
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
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

                Spacer()

                Text(CostEstimator.format(estimatedCost))
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .help("Estimated cost at fal's listed prices. Actual billing may differ.")

                submitButton
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
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
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(selectedVoice.isEmpty ? (audioModel.defaultVoice ?? "Voice") : selectedVoice)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, 3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
        HStack(spacing: 0) {
            ForEach(FramesRefsMode.allCases, id: \.self) { mode in
                Button {
                    framesRefsMode = mode
                    switch mode {
                    case .firstLast: resetRefPools()
                    case .reference: firstFrame = nil; lastFrame = nil
                    }
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .foregroundStyle(framesRefsMode == mode
                            ? AppTheme.Text.primaryColor
                            : AppTheme.Text.tertiaryColor)
                        .padding(.horizontal, AppTheme.Spacing.sm)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.concentric(outer: AppTheme.Radius.sm, padding: 2))
                                .fill(framesRefsMode == mode ? Color.white.opacity(0.08) : .clear)
                        )
                        .hoverHighlight(cornerRadius: AppTheme.Radius.concentric(outer: AppTheme.Radius.sm, padding: 2))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: 1)
        )
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
                columns: [GridItem(.adaptive(minimum: 80), spacing: AppTheme.Spacing.xs)],
                alignment: .leading,
                spacing: AppTheme.Spacing.xs
            ) {
                ForEach(ClipType.allCases, id: \.self) { type in
                    refCards(for: type)
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

    private func refCap(for type: ClipType) -> Int {
        switch type {
        case .image: videoModel.maxReferenceImages
        case .video: videoModel.maxReferenceVideos
        case .audio: videoModel.maxReferenceAudios
        }
    }

    private func refCount(for type: ClipType) -> Int {
        switch type {
        case .image: refImages.count
        case .video: refVideos.count
        case .audio: refAudios.count
        }
    }

    /// Tag noun used in `@Image1` / `@Video1` / `@Audio1` / `@Element1` labels.
    private func tagNoun(for type: ClipType) -> String {
        switch type {
        case .image: videoModel.referenceTagNoun
        case .video: "Video"
        case .audio: "Audio"
        }
    }

    private func addRefAsset(_ asset: MediaAsset) {
        if allRefs.contains(where: { $0.id == asset.id }) {
            flashDropError("\(asset.name) is already a reference")
            return
        }
        if refCap(for: asset.type) == 0 {
            let supported = ClipType.allCases.filter { refCap(for: $0) > 0 }.map(\.rawValue)
            flashDropError("\(videoModel.displayName) only accepts \(supported.joined(separator: "/")) references")
            return
        }
        if isRefCapReached {
            flashDropError("Max \(videoModel.maxTotalReferences ?? refCap(for: asset.type)) references")
            return
        }
        if refCount(for: asset.type) >= refCap(for: asset.type) {
            flashDropError("Max \(refCap(for: asset.type)) \(asset.type.rawValue) references")
            return
        }
        if let cap = combinedDurationCap(for: asset.type),
           combinedDuration(for: asset.type) + asset.duration > cap {
            flashDropError("\(asset.type.rawValue.capitalized) refs combined can't exceed \(Int(cap))s")
            return
        }
        switch asset.type {
        case .image: refImages.append(asset)
        case .video: refVideos.append(asset)
        case .audio: refAudios.append(asset)
        }
    }

    private func validatedDropZone(
        isTargeted: Binding<Bool>,
        expects: Set<ClipType>,
        iconName: String,
        roleLabel: String,
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
                let types = expects.map(\.rawValue).sorted().joined(separator: "/")
                flashDropError("\(roleLabel) expects \(types)")
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

    private func combinedDurationCap(for type: ClipType) -> Double? {
        switch type {
        case .video: videoModel.maxCombinedVideoRefSeconds
        case .audio: videoModel.maxCombinedAudioRefSeconds
        case .image: nil
        }
    }

    private func combinedDuration(for type: ClipType) -> Double {
        switch type {
        case .video: refVideos.reduce(0) { $0 + $1.duration }
        case .audio: refAudios.reduce(0) { $0 + $1.duration }
        case .image: 0
        }
    }

    private func removeRef(_ type: ClipType, at index: Int) {
        switch type {
        case .image: refImages.remove(at: index)
        case .video: refVideos.remove(at: index)
        case .audio: refAudios.remove(at: index)
        }
    }

    @ViewBuilder
    private func refCards(for type: ClipType) -> some View {
        let assets: [MediaAsset] = {
            switch type { case .image: refImages; case .video: refVideos; case .audio: refAudios }
        }()
        let noun = tagNoun(for: type)
        ForEach(Array(assets.enumerated()), id: \.element.id) { index, asset in
            refCard(asset: asset, tag: "@\(noun)\(index + 1)") {
                removeRef(type, at: index)
            }
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
            let shortLabel: (ClipType) -> String = { switch $0 { case .image: "img"; case .video: "vid"; case .audio: "aud" } }
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
                .frame(width: 80, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Border.primaryColor, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    Button { onClear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.8))
                            .shadow(radius: 2)
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } else {
                validatedDropZone(
                    isTargeted: isTargeted,
                    expects: acceptedTypes,
                    iconName: iconName,
                    roleLabel: label,
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
                columns: [GridItem(.adaptive(minimum: 80), spacing: AppTheme.Spacing.xs)],
                alignment: .leading,
                spacing: AppTheme.Spacing.xs
            ) {
                ForEach(Array(imageReferences.enumerated()), id: \.element.id) { index, asset in
                    refCard(asset: asset) { imageReferences.remove(at: index) }
                }
                validatedDropZone(
                    isTargeted: $imageRefTargeted,
                    expects: [.image],
                    iconName: "photo.badge.plus",
                    roleLabel: "Reference"
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
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
        }
        .frame(width: 80, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
            .strokeBorder(AppTheme.Border.primaryColor, lineWidth: 1))
        .overlay(alignment: .bottomLeading) {
            if let tag {
                Text(tag)
                    .font(.system(size: 9, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(3)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { onRemove() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.8))
                    .shadow(radius: 2)
                    .frame(width: 20, height: 20)
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
            .font(.system(size: 12))
            .foregroundStyle(isTargeted.wrappedValue ? Color.accentColor : AppTheme.Text.mutedColor)
            .frame(width: 80, height: 56)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(isTargeted.wrappedValue ? Color.accentColor.opacity(0.08) : Color.white.opacity(0.02))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        isTargeted.wrappedValue ? Color.accentColor.opacity(0.5) : AppTheme.Border.primaryColor,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
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
        Button { submitGeneration() } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 24))
        }
        .buttonStyle(.plain)
        .foregroundStyle(canSubmit ? Color.accentColor : AppTheme.Text.mutedColor)
        .disabled(!canSubmit)
    }

    // MARK: - Type picker

    private var typeTabs: some View {
        ViewThatFits(in: .horizontal) {
            typeTabsBar(showLabels: true)
            typeTabsBar(showLabels: false)
        }
    }

    private func typeTabsBar(showLabels: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(GenerationType.allCases, id: \.self) { type in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedType = type }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: type.icon)
                            .font(.system(size: 9, weight: .medium))
                        if showLabels {
                            Text(type.rawValue)
                                .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                                .fixedSize()
                        }
                    }
                    .foregroundStyle(selectedType == type ? type.accentColor : AppTheme.Text.tertiaryColor)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.concentric(outer: AppTheme.Radius.sm, padding: 2))
                            .fill(selectedType == type ? type.accentColor.opacity(0.12) : .clear)
                    )
                    .hoverHighlight(cornerRadius: AppTheme.Radius.concentric(outer: AppTheme.Radius.sm, padding: 2))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: 1)
        )
    }

    // MARK: - Model picker

    private var modelPicker: some View {
        Menu {
            switch selectedType {
            case .video:
                ForEach(Array(VideoModelConfig.allModels.enumerated()), id: \.offset) { index, m in
                    Button(m.displayName) { selectedVideoModelIndex = index }
                }
            case .image:
                ForEach(Array(ImageModelConfig.allModels.enumerated()), id: \.offset) { index, m in
                    Button(m.displayName) { selectedImageModelIndex = index }
                }
            case .audio:
                ForEach(Array(AudioModelConfig.allModels.enumerated()), id: \.offset) { index, m in
                    Button(m.displayName) { selectedAudioModelIndex = index }
                }
            }
        } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(currentModelName)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, 3)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
                if supportsAudioToggle {
                    Image(systemName: generateAudio ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                Image(systemName: "gearshape")
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, 3)
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
                                        .fill(selection.wrappedValue == option ? Color.white.opacity(0.1) : Color.white.opacity(0.03))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - API key

    private var apiKeyButton: some View {
        ApiKeyField(
            label: "fal",
            placeholder: "Paste fal.ai API key",
            hasKey: editor.generationService.hasApiKey,
            maskedKey: editor.generationService.maskedApiKey,
            onSave: { editor.generationService.setApiKey($0) },
            onDelete: { editor.generationService.removeApiKey() }
        )
    }

    // MARK: - Actions

    private func submitGeneration() {
        let audioDuration: Int = {
            guard selectedType == .audio else { return 0 }
            return audioModel.durations != nil ? selectedAudioDuration : 0
        }()
        var genInput = GenerationInput(
            prompt: prompt,
            model: currentModelId,
            duration: selectedType == .video ? selectedDuration : audioDuration,
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
        genInput.estimatedCost = estimatedCost

        let trimmedName = assetName.trimmingCharacters(in: .whitespaces)
        let name: String? = trimmedName.isEmpty ? nil : trimmedName

        // Set "Generating..." overlay on the target clip.
        let replacementClipId = editor.pendingEditReplacementClipId
        editor.pendingEditReplacementClipId = nil
        let editorRef = editor
        let onComplete: (@MainActor (MediaAsset) -> Void)?
        let onFailure: (@MainActor () -> Void)?
        var didTrimSource = false
        if let clipId = replacementClipId {
            editor.markPendingReplacement(clipId: clipId)
            // N-image generations call onComplete once per finalized asset; the
            // first one swaps the clip, subsequent assets just land in the media
            // library as siblings.
            let firstOnly = FirstOnlyFlag()
            onComplete = { [weak editorRef] newAsset in
                guard firstOnly.fire() else { return }
                editorRef?.replaceClipMediaRef(clipId: clipId, newAssetId: newAsset.id, resetTrim: didTrimSource)
                editorRef?.clearPendingReplacement(clipId: clipId)
            }
            onFailure = { [weak editorRef] in
                editorRef?.clearPendingReplacement(clipId: clipId)
            }
        } else {
            onComplete = nil
            onFailure = nil
        }

        switch selectedType {
        case .video:
            let model = videoModel
            let useRefs = !model.requiresSourceVideo && showsRefSections
            let useFrames = !model.requiresSourceVideo && showsFrameStrip
            var refs: [MediaAsset] = []
            var frameSlots: [MediaAsset] = []
            if model.requiresSourceVideo {
                if let sv = sourceVideo { refs.append(sv) }
                if model.supportsReferences, let imgRef = imageReferences.first {
                    refs.append(imgRef)
                }
            } else {
                if useFrames {
                    if let f = firstFrame { frameSlots.append(f) }
                    if let l = lastFrame { frameSlots.append(l) }
                }
                refs.append(contentsOf: frameSlots)
                if useRefs {
                    refs.append(contentsOf: refImages)
                    refs.append(contentsOf: refVideos)
                    refs.append(contentsOf: refAudios)
                }
            }
            let frameCount = frameSlots.count
            let imageRefCount = useRefs ? refImages.count : 0
            let videoRefCount = useRefs ? refVideos.count : 0
            let audioRefCount = useRefs ? refAudios.count : 0
            let trimmedSource: TrimmedSource? = {
                guard model.requiresSourceVideo,
                      let trim = editor.pendingEditTrimmedSource,
                      let sv = sourceVideo,
                      trim.sourceURL == sv.url else { return nil }
                return trim
            }()
            editor.pendingEditTrimmedSource = nil
            didTrimSource = (trimmedSource?.hasTrim == true)
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
            let generateAudioValue = effectiveGenerateAudio
            var snapshotRefs: (@Sendable (inout GenerationInput, [String]) -> Void)? = nil
            if !model.requiresSourceVideo {
                snapshotRefs = { input, uploaded in
                    let frames = Array(uploaded.prefix(frameCount))
                    let rest = Array(uploaded.dropFirst(frameCount))
                    input.imageURLs = frames.isEmpty ? nil : frames
                    input.referenceImageURLs = imageRefCount > 0 ? Array(rest.prefix(imageRefCount)) : nil
                    input.referenceVideoURLs = videoRefCount > 0
                        ? Array(rest.dropFirst(imageRefCount).prefix(videoRefCount)) : nil
                    input.referenceAudioURLs = audioRefCount > 0
                        ? Array(rest.dropFirst(imageRefCount + videoRefCount).prefix(audioRefCount)) : nil
                }
            }
            // Downscale ref videos to fit Seedance's ~1112 px long-side cap before upload.
            var preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)? = nil
            if useRefs {
                preprocessRef = { _, asset in
                    guard asset.type == .video else { return nil }
                    return try await VideoCompressor.compressIfNeeded(url: asset.url)
                }
            }
            editor.generationService.generate(
                genInput: genInput,
                assetType: .video,
                placeholderDuration: placeholderDuration,
                references: refs,
                trimmedSourceOverride: trimmedSource,
                name: name,
                buildInput: { uploaded in
                    let params: VideoGenerationParams
                    if model.requiresSourceVideo {
                        params = VideoGenerationParams(
                            prompt: genInput.prompt,
                            duration: genInput.duration,
                            aspectRatio: genInput.aspectRatio,
                            resolution: genInput.resolution,
                            sourceVideoURL: uploaded.first,
                            startFrameURL: nil,
                            endFrameURL: nil,
                            referenceImageURLs: Array(uploaded.dropFirst()),
                            generateAudio: generateAudioValue
                        )
                    } else {
                        let frames = Array(uploaded.prefix(frameCount))
                        let rest = Array(uploaded.dropFirst(frameCount))
                        let images = Array(rest.prefix(imageRefCount))
                        let videos = Array(rest.dropFirst(imageRefCount).prefix(videoRefCount))
                        let audios = Array(rest.dropFirst(imageRefCount + videoRefCount).prefix(audioRefCount))
                        params = VideoGenerationParams(
                            prompt: genInput.prompt,
                            duration: genInput.duration,
                            aspectRatio: genInput.aspectRatio,
                            resolution: genInput.resolution,
                            sourceVideoURL: nil,
                            startFrameURL: frames.first,
                            endFrameURL: frames.count > 1 ? frames[1] : nil,
                            referenceImageURLs: images,
                            referenceVideoURLs: videos,
                            referenceAudioURLs: audios,
                            generateAudio: generateAudioValue
                        )
                    }
                    return (model.resolvedEndpoint(params: params), model.buildInput(params: params))
                },
                snapshotRefs: snapshotRefs,
                preprocessRef: preprocessRef,
                responseKeyPath: FalResponsePaths.video,
                fileExtension: "mp4",
                projectURL: editor.projectURL, editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        case .image:
            let model = imageModel
            editor.generationService.generate(
                genInput: genInput,
                assetType: .image,
                placeholderDuration: Defaults.imageDurationSeconds,
                references: imageReferences,
                name: name,
                numImages: imageCount,
                buildInput: { uploaded in
                    let input = model.buildInput(
                        prompt: genInput.prompt, aspectRatio: genInput.aspectRatio,
                        resolution: genInput.resolution, quality: genInput.quality,
                        imageURLs: uploaded, numImages: imageCount
                    )
                    return (model.resolvedEndpoint(imageURLs: uploaded), input)
                },
                responseKeyPath: FalResponsePaths.generatedImage,
                fileExtension: "jpg",
                projectURL: editor.projectURL, editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        case .audio:
            let model = audioModel
            let placeholderDuration: Double = {
                if model.durations != nil { return Double(audioDuration) }
                return model.category == .music
                    ? Defaults.audioMusicDurationSeconds
                    : Defaults.audioTTSDurationSeconds
            }()
            let params = AudioGenerationParams(
                prompt: genInput.prompt,
                voice: genInput.voice,
                lyrics: genInput.lyrics,
                styleInstructions: genInput.styleInstructions,
                instrumental: genInput.instrumental ?? false,
                durationSeconds: model.durations != nil ? audioDuration : nil
            )
            editor.generationService.generate(
                genInput: genInput,
                assetType: .audio,
                placeholderDuration: placeholderDuration,
                name: name,
                buildInput: { _ in
                    (model.baseEndpoint, model.buildInput(params: params))
                },
                responseKeyPath: FalResponsePaths.audio,
                fileExtension: "mp3",
                projectURL: editor.projectURL, editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }
        lyrics = ""
        styleInstructions = ""
        prompt = ""
        assetName = ""
        clearReferences()
    }

    private func clearReferences() {
        firstFrame = nil
        lastFrame = nil
        imageReferences.removeAll()
        resetRefPools()
        sourceVideo = nil
    }

    /// Read `editor.pendingEditSource`, set up the edit flow, and clear the signal.
    private func consumePendingEditSource() {
        guard let source = editor.pendingEditSource else { return }
        isConsumingEditSource = true
        defer {
            DispatchQueue.main.async { isConsumingEditSource = false }
        }
        switch source.type {
        case .video:
            selectedType = .video
            if let idx = VideoModelConfig.allModels.firstIndex(where: { $0.requiresSourceVideo }) {
                selectedVideoModelIndex = idx
            }
            sourceVideo = source
            firstFrame = nil
            lastFrame = nil
            imageReferences.removeAll()
        case .image:
            selectedType = .image
            if let idx = ImageModelConfig.allModels.firstIndex(where: { $0.id == ImageModelConfig.nanoBananaPro.id }) {
                selectedImageModelIndex = idx
            }
            imageReferences = [source]
            sourceVideo = nil
            firstFrame = nil
            lastFrame = nil
        case .audio:
            editor.pendingEditSource = nil
            return
        }
        if assetName.isEmpty {
            assetName = "Edited \(source.name)"
        }
        editor.pendingEditSource = nil
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