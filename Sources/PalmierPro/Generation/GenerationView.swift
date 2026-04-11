import SwiftUI

struct GenerationView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var service = GenerationService()
    @State private var prompt = ""
    @State private var selectedType: GenerationType = .video
    @State private var selectedVideoModelIndex = 0
    @State private var selectedImageModelIndex = 0
    @State private var selectedDuration = 5
    @State private var selectedAspectRatio = "16:9"
    @State private var selectedResolution = "1080p"
    @State private var showSettingsPopover = false
    @FocusState private var isPromptFocused: Bool

    var selectedAssets: [MediaAsset] = []

    enum GenerationType: String, CaseIterable {
        case image = "AI Image"
        case video = "AI Video"
        case audio = "AI Audio"

        var icon: String {
            switch self {
            case .image: "photo"
            case .video: "video"
            case .audio: "waveform"
            }
        }
    }

    // MARK: - Computed state

    private var videoModel: VideoModelConfig { VideoModelConfig.allModels[selectedVideoModelIndex] }
    private var imageModel: ImageModelConfig { ImageModelConfig.allModels[selectedImageModelIndex] }
    private var isPromptEmpty: Bool { prompt.trimmingCharacters(in: .whitespaces).isEmpty }
    private var canSubmit: Bool { !isPromptEmpty && selectedType != .audio }

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
        VStack(alignment: .leading, spacing: 0) {
            if !service.hasApiKey {
                Text("Enter your fal.ai API key in Settings")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .padding(AppTheme.Spacing.lg)
            } else {
                generationForm
                    .padding(AppTheme.Spacing.md)
            }
        }
    }

    // MARK: - Form

    private var generationForm: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.sm) {
                typePicker
                modelPicker
                if selectedType != .audio { settingsButton }
            }

            if !selectedAssets.isEmpty { referenceStrip }

            HStack(alignment: .bottom, spacing: AppTheme.Spacing.sm) {
                promptField
                submitButton
            }
        }
        .onChange(of: selectedType) { _, _ in resetSettings() }
        .onChange(of: selectedVideoModelIndex) { _, _ in if selectedType == .video { resetSettings() } }
        .onChange(of: selectedImageModelIndex) { _, _ in if selectedType == .image { resetSettings() } }
    }

    // MARK: - Prompt

    private var promptField: some View {
        TextField(promptPlaceholder, text: $prompt, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: AppTheme.FontSize.sm))
            .lineLimit(4...12)
            .padding(AppTheme.Spacing.sm)
            .frame(minHeight: 80)
            .focused($isPromptFocused)
            .controlBackground(
                borderColor: isPromptFocused ? Color.accentColor.opacity(0.5) : AppTheme.Border.primaryColor
            )
    }

    private var submitButton: some View {
        Button { submitGeneration() } label: {
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 22))
        }
        .buttonStyle(.plain)
        .foregroundStyle(canSubmit ? Color.accentColor : AppTheme.Text.mutedColor)
        .disabled(!canSubmit)
    }

    // MARK: - References

    private var referenceStrip: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("References")
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    ForEach(selectedAssets) { asset in
                        referenceThumbnail(asset)
                    }
                }
            }
        }
    }

    private func referenceThumbnail(_ asset: MediaAsset) -> some View {
        Group {
            if let thumbnail = asset.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: asset.type.sfSymbolName)
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
        }
        .frame(width: 56, height: 40)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: 1)
        )
    }

    // MARK: - Type picker

    private var typePicker: some View {
        Menu {
            ForEach(GenerationType.allCases, id: \.self) { type in
                Button { selectedType = type } label: {
                    Label(type.rawValue, systemImage: type.icon)
                }
            }
        } label: {
            Image(systemName: selectedType.icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 28, height: 28)
                .controlBackground()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: 28)
            .controlBackground()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Settings

    private var settingsButton: some View {
        Button { showSettingsPopover.toggle() } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(settingsSummary)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .lineLimit(1)
                Image(systemName: "gearshape")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .frame(height: 28)
            .controlBackground()
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
            Picker("", selection: selection) {
                ForEach(options, id: \.self) { option in
                    Text(format(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
    }

    // MARK: - Actions

    private func submitGeneration() {
        switch selectedType {
        case .video:
            service.generateVideo(
                model: videoModel, prompt: prompt, duration: selectedDuration,
                aspectRatio: selectedAspectRatio,
                resolution: videoModel.resolutions != nil ? selectedResolution : nil,
                projectURL: editor.projectURL, editor: editor
            )
        case .image:
            service.generateImage(
                model: imageModel, prompt: prompt, aspectRatio: selectedAspectRatio,
                resolution: imageModel.resolutions != nil ? selectedResolution : nil,
                projectURL: editor.projectURL, editor: editor
            )
        case .audio:
            // TODO: Implement audio generation
            return
        }
        prompt = ""
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

private extension View {
    func controlBackground(borderColor: Color = AppTheme.Border.primaryColor) -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
    }
}
