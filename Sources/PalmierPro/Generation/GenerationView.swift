import SwiftUI

struct GenerationView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var service = GenerationService()
    @State private var prompt = ""
    @State private var assetName = ""
    @State private var selectedType: GenerationType = .video
    @State private var selectedVideoModelIndex = 0
    @State private var selectedImageModelIndex = 0
    @State private var selectedDuration = 5
    @State private var selectedAspectRatio = "16:9"
    @State private var selectedResolution = "1080p"
    @State private var showSettingsPopover = false
    @FocusState private var isPromptFocused: Bool

    // API key
    @State private var apiKeyDraft = ""
    @State private var showApiKeyPopover = false

    // Video frame references
    @State private var firstFrame: MediaAsset?
    @State private var lastFrame: MediaAsset?
    @State private var firstFrameTargeted = false
    @State private var lastFrameTargeted = false

    // Image references
    @State private var imageReferences: [MediaAsset] = []
    @State private var imageRefTargeted = false

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
    private var isPromptEmpty: Bool { prompt.trimmingCharacters(in: .whitespaces).isEmpty }
    private var canSubmit: Bool { !isPromptEmpty && selectedType != .audio && service.hasApiKey }

    private var currentModelName: String {
        switch selectedType {
        case .video: videoModel.displayName
        case .image: imageModel.displayName
        case .audio: "Coming soon"
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

    private var promptPlaceholder: String {
        switch selectedType {
        case .image: "Describe the image..."
        case .video: "Describe the video..."
        case .audio: "Describe the audio..."
        }
    }

    private var settingsSummary: String {
        var parts: [String] = []
        if currentResolutions != nil { parts.append(selectedResolution) }
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
                Button { editor.showGenerationPanel = false } label: {
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
            if selectedType == .video && videoModel.supportsFirstFrame {
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
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.lg)
                .fill(.ultraThinMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.lg))
        .padding(AppTheme.Spacing.sm)
        .onChange(of: selectedType) { _, _ in
            resetSettings()
            clearReferences()
        }
        .onChange(of: selectedVideoModelIndex) { _, _ in
            if selectedType == .video {
                resetSettings()
                clearReferences()
            }
        }
        .onChange(of: selectedImageModelIndex) { _, _ in
            if selectedType == .image {
                resetSettings()
                clearReferences()
            }
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

    // MARK: - Input toolbar (bottom of input box)

    private var inputToolbar: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 0.5)
            HStack(spacing: AppTheme.Spacing.sm) {
                modelPicker
                if selectedType != .audio { settingsButton }

                Spacer()

                submitButton
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
        }
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
                dropZone(isTargeted: isTargeted) { onDrop($0) }
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

    // MARK: - Shared drop zone

    private func dropZone(isTargeted: Binding<Bool>, onDrop: @escaping (MediaAsset) -> Void) -> some View {
        Image(systemName: "photo.badge.plus")
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
                        $0.url.absoluteString == urlString && $0.type == .image
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
                Text("Coming soon")
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
            if !currentAspectRatios.isEmpty {
                settingsPicker("Aspect Ratio", selection: $selectedAspectRatio, options: currentAspectRatios) { $0 }
            }
            if let resolutions = currentResolutions {
                settingsPicker("Resolution", selection: $selectedResolution, options: resolutions) { $0 }
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
        Button { showApiKeyPopover.toggle() } label: {
            HStack(spacing: 3) {
                Image(systemName: "key")
                    .font(.system(size: 9, weight: .medium))
                Text("fal")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            }
            .foregroundStyle(service.hasApiKey ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, 3)
            .hoverHighlight()
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showApiKeyPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                if service.hasApiKey {
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text(service.maskedApiKey)
                            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Spacer()
                        Button(role: .destructive) {
                            service.removeApiKey()
                            showApiKeyPopover = false
                        } label: {
                            Image(systemName: "trash").font(.system(size: AppTheme.FontSize.xs))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                HStack(spacing: AppTheme.Spacing.sm) {
                    SecureField(service.hasApiKey ? "Replace API key" : "Paste fal.ai API key", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .controlSize(.small)
                        .onSubmit { saveApiKey() }
                    Button("Save") { saveApiKey() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(AppTheme.Spacing.lg)
            .frame(width: 320)
        }
    }

    private func saveApiKey() {
        let key = apiKeyDraft.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return }
        service.setApiKey(key)
        apiKeyDraft = ""
        showApiKeyPopover = false
    }

    // MARK: - Actions

    private func submitGeneration() {
        let genInput = GenerationInput(
            prompt: prompt,
            model: currentModelName,
            duration: selectedType == .video ? selectedDuration : 0,
            aspectRatio: selectedAspectRatio,
            resolution: selectedType == .video
                ? (videoModel.resolutions != nil ? selectedResolution : nil)
                : (imageModel.resolutions != nil ? selectedResolution : nil)
        )

        let trimmedName = assetName.trimmingCharacters(in: .whitespaces)
        let name: String? = trimmedName.isEmpty ? nil : trimmedName

        switch selectedType {
        case .video:
            let model = videoModel
            var frameRefs: [MediaAsset] = []
            if let f = firstFrame { frameRefs.append(f) }
            if let l = lastFrame { frameRefs.append(l) }
            service.generate(
                genInput: genInput,
                assetType: .video,
                placeholderDuration: Double(selectedDuration),
                references: frameRefs,
                name: name,
                buildInput: { uploaded in
                    let params = VideoGenerationParams(
                        prompt: genInput.prompt,
                        duration: genInput.duration,
                        aspectRatio: genInput.aspectRatio,
                        resolution: genInput.resolution,
                        startFrameURL: uploaded.first,
                        endFrameURL: uploaded.count > 1 ? uploaded[1] : nil,
                        referenceImageURLs: [],
                        generateAudio: true
                    )
                    return (model.resolvedEndpoint(params: params), model.buildInput(params: params))
                },
                responseKeyPath: { $0["video"]["url"].stringValue },
                fileExtension: "mp4",
                projectURL: editor.projectURL, editor: editor
            )
        case .image:
            let model = imageModel
            service.generate(
                genInput: genInput,
                assetType: .image,
                placeholderDuration: Defaults.imageDurationSeconds,
                references: imageReferences,
                name: name,
                buildInput: { uploaded in
                    let input = model.buildInput(
                        prompt: genInput.prompt, aspectRatio: genInput.aspectRatio,
                        resolution: genInput.resolution, imageURLs: uploaded
                    )
                    return (model.resolvedEndpoint(imageURLs: uploaded), input)
                },
                responseKeyPath: { $0["images"][0]["url"].stringValue },
                fileExtension: "jpg",
                projectURL: editor.projectURL, editor: editor
            )
        case .audio:
            return
        }
        prompt = ""
        assetName = ""
        clearReferences()
    }

    private func clearReferences() {
        firstFrame = nil
        lastFrame = nil
        imageReferences.removeAll()
    }

    private func resetSettings() {
        if !currentAspectRatios.contains(selectedAspectRatio) {
            selectedAspectRatio = currentAspectRatios.first ?? "16:9"
        }
        if let resolutions = currentResolutions, !resolutions.contains(selectedResolution) {
            selectedResolution = resolutions.first ?? "1080p"
        }
        if selectedType == .video, !videoModel.durations.contains(selectedDuration) {
            selectedDuration = videoModel.durations.first ?? 5
        }
    }
}