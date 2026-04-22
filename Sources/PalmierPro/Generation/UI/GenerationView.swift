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

    // Audio extras
    @State private var selectedVoice = ""
    @State private var lyrics = ""
    @State private var styleInstructions = ""
    @State private var instrumental = false
    @State private var selectedAudioDuration = 30
    @State private var showSettingsPopover = false
    @FocusState private var isPromptFocused: Bool

    // Video frame references
    @State private var firstFrame: MediaAsset?
    @State private var lastFrame: MediaAsset?
    @State private var firstFrameTargeted = false
    @State private var lastFrameTargeted = false

    // Image references
    @State private var imageReferences: [MediaAsset] = []
    @State private var imageRefTargeted = false

    // Source video (for video-to-video edit models)
    @State private var sourceVideo: MediaAsset?
    @State private var sourceVideoTargeted = false
    @State private var motionReferenceTargeted = false

    @State private var isConsumingEditSource = false

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
        if selectedType == .audio {
            return trimmedPrompt.count >= audioModel.minPromptLength
        }
        return !isPromptEmpty
    }

    private var hasAnySettings: Bool {
        switch selectedType {
        case .video: return !videoModel.durations.isEmpty || !videoModel.aspectRatios.isEmpty || videoModel.resolutions != nil
        case .image: return !imageModel.aspectRatios.isEmpty || imageModel.resolutions != nil || imageModel.qualities != nil
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

    private var currentQualities: [String]? {
        selectedType == .image ? imageModel.qualities : nil
    }

    private var audioPromptHint: String {
        audioModel.minPromptLength > 1 ? " (min \(audioModel.minPromptLength) chars)" : ""
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

    private var settingsSummary: String {
        var parts: [String] = []
        if selectedType == .audio {
            if audioModel.durations != nil { parts.append("\(selectedAudioDuration)s") }
            if audioModel.supportsInstrumental && instrumental { parts.append("Instrumental") }
            return parts.isEmpty ? "Settings" : parts.joined(separator: " \u{00B7} ")
        }
        if currentResolutions != nil { parts.append(selectedResolution) }
        if currentQualities != nil { parts.append(selectedQuality) }
        if selectedType == .video { parts.append("\(selectedDuration)s") }
        parts.append(selectedAspectRatio)
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            // Type tabs + API key on top row
            HStack {
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
            } else if selectedType == .video && videoModel.supportsFirstFrame {
                videoFrameStrip
                    .padding(.horizontal, AppTheme.Spacing.md)
            } else if selectedType == .image && imageModel.supportsImageReference {
                imageReferenceStrip
                    .padding(.horizontal, AppTheme.Spacing.md)
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
                dropZone(isTargeted: isTargeted, accepting: acceptedTypes, iconName: iconName) { onDrop($0) }
            }
        }
    }

    // MARK: - Image references

    private var imageReferenceStrip: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("References")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(Array(imageReferences.enumerated()), id: \.element.id) { index, asset in
                        refCard(asset: asset) { imageReferences.remove(at: index) }
                    }
                    dropZone(isTargeted: $imageRefTargeted) { imageReferences.append($0) }
                }
            }
        }
    }

    private func refCard(asset: MediaAsset, onRemove: @escaping () -> Void) -> some View {
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
                DropTargetOverlay(isTargeted: isTargeted) { urlString in
                    if let asset = editor.mediaAssets.first(where: {
                        $0.url.absoluteString == urlString && acceptedTypes.contains($0.type)
                    }) {
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
        HStack(spacing: 0) {
            ForEach(GenerationType.allCases, id: \.self) { type in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { selectedType = type }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: type.icon)
                            .font(.system(size: 9, weight: .medium))
                        Text(type.rawValue)
                            .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    }
                    .foregroundStyle(selectedType == type ? type.accentColor : AppTheme.Text.tertiaryColor)
                    .padding(.horizontal, AppTheme.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.concentric(outer: AppTheme.Radius.sm, padding: 2))
                            .fill(selectedType == type ? type.accentColor.opacity(0.12) : .clear)
                    )
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
                settingsPicker("Resolution", selection: $selectedResolution, options: resolutions) { $0 }
            }
            if let qualities = currentQualities {
                settingsPicker("Quality", selection: $selectedQuality, options: qualities) { $0.capitalized }
            }
            if selectedType == .audio && audioModel.supportsInstrumental {
                Toggle("Instrumental", isOn: $instrumental)
                    .controlSize(.small)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
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
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
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
        let genInput = GenerationInput(
            prompt: prompt,
            model: currentModelId,
            duration: selectedType == .video ? selectedDuration : audioDuration,
            aspectRatio: selectedAspectRatio,
            resolution: selectedType == .video
                ? (videoModel.resolutions != nil ? selectedResolution : nil)
                : (selectedType == .image && imageModel.resolutions != nil ? selectedResolution : nil),
            quality: selectedType == .image && imageModel.qualities != nil ? selectedQuality : nil,
            voice: selectedType == .audio && audioModel.voices != nil && !selectedVoice.isEmpty
                ? selectedVoice : nil,
            lyrics: selectedType == .audio && audioModel.supportsLyrics && !lyrics.isEmpty
                ? lyrics : nil,
            styleInstructions: selectedType == .audio && audioModel.supportsStyleInstructions && !styleInstructions.isEmpty
                ? styleInstructions : nil,
            instrumental: selectedType == .audio && audioModel.supportsInstrumental
                ? instrumental : nil
        )

        let trimmedName = assetName.trimmingCharacters(in: .whitespaces)
        let name: String? = trimmedName.isEmpty ? nil : trimmedName

        // Set "Generating..." overlay on the target clip.
        let replacementClipId = editor.pendingEditReplacementClipId
        editor.pendingEditReplacementClipId = nil
        let editorRef = editor
        let onComplete: (@MainActor (MediaAsset) -> Void)?
        let onFailure: (@MainActor () -> Void)?
        if let clipId = replacementClipId {
            editor.markPendingReplacement(clipId: clipId)
            onComplete = { [weak editorRef] newAsset in
                editorRef?.replaceClipMediaRef(clipId: clipId, newAssetId: newAsset.id)
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
            var refs: [MediaAsset] = []
            if model.requiresSourceVideo {
                if let sv = sourceVideo { refs.append(sv) }
                if model.supportsReferences, let imgRef = imageReferences.first {
                    refs.append(imgRef)
                }
            } else {
                if let f = firstFrame { refs.append(f) }
                if let l = lastFrame { refs.append(l) }
            }
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
            editor.generationService.generate(
                genInput: genInput,
                assetType: .video,
                placeholderDuration: placeholderDuration,
                references: refs,
                trimmedSourceOverride: trimmedSource,
                name: name,
                buildInput: { uploaded in
                    let params = VideoGenerationParams(
                        prompt: genInput.prompt,
                        duration: genInput.duration,
                        aspectRatio: genInput.aspectRatio,
                        resolution: genInput.resolution,
                        sourceVideoURL: model.requiresSourceVideo ? uploaded.first : nil,
                        startFrameURL: model.requiresSourceVideo ? nil : uploaded.first,
                        endFrameURL: model.requiresSourceVideo ? nil : (uploaded.count > 1 ? uploaded[1] : nil),
                        referenceImageURLs: model.requiresSourceVideo ? Array(uploaded.dropFirst()) : [],
                        generateAudio: true
                    )
                    return (model.resolvedEndpoint(params: params), model.buildInput(params: params))
                },
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
                buildInput: { uploaded in
                    let input = model.buildInput(
                        prompt: genInput.prompt, aspectRatio: genInput.aspectRatio,
                        resolution: genInput.resolution, quality: genInput.quality,
                        imageURLs: uploaded
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
    }
}