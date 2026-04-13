import SwiftUI

struct InspectorView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let clip = selectedClip {
                    clipInspectorContent(clip)
                } else if let asset = selectedMediaAsset {
                    mediaAssetInspectorContent(asset)
                } else {
                    Color.clear
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.Background.panelColor)
    }

    // MARK: - Clip Inspector

    @ViewBuilder
    private func clipInspectorContent(_ clip: Clip) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                frameSection(clip)

                sectionDivider

                // Scale
                InspectorSlider(
                    icon: "arrow.up.left.and.arrow.down.right",
                    label: "Scale",
                    value: clip.transform.width,
                    range: 0.01...5.0,
                    displayMultiplier: 100,
                    valueSuffix: "%",
                    format: "%.0f",
                    onChanged: { newVal in
                        editor.applyClipProperty(clipId: clip.id) {
                            let old = $0.transform.topLeft
                            let cx = old.x + $0.transform.width / 2.0
                            let cy = old.y + $0.transform.height / 2.0
                            $0.transform = Transform(topLeft: (cx - newVal / 2.0, cy - newVal / 2.0), width: newVal, height: newVal)
                        }
                    }
                ) { newVal in
                    editor.commitClipProperty(clipId: clip.id) {
                        let old = $0.transform.topLeft
                        let cx = old.x + $0.transform.width / 2.0
                        let cy = old.y + $0.transform.height / 2.0
                        $0.transform = Transform(topLeft: (cx - newVal / 2.0, cy - newVal / 2.0), width: newVal, height: newVal)
                    }
                }

                sectionDivider

                InspectorSlider(
                    icon: "circle.lefthalf.filled",
                    label: "Opacity",
                    value: clip.opacity,
                    range: 0...1,
                    displayMultiplier: 100,
                    valueSuffix: "%",
                    format: "%.0f",
                    onChanged: { newVal in
                        editor.applyClipProperty(clipId: clip.id) { $0.opacity = newVal }
                    }
                ) { newVal in
                    editor.commitClipProperty(clipId: clip.id) { $0.opacity = newVal }
                }

                sectionDivider

                // Volume
                InspectorSlider(
                    icon: "speaker.wave.2.fill",
                    label: "Volume",
                    value: clip.volume,
                    range: 0...1,
                    displayMultiplier: 100,
                    valueSuffix: "%",
                    format: "%.0f",
                    onChanged: { newVal in
                        editor.applyClipProperty(clipId: clip.id) { $0.volume = newVal }
                    }
                ) { newVal in
                    editor.commitClipProperty(clipId: clip.id) { $0.volume = newVal }
                }

                sectionDivider

                // Speed
                InspectorSlider(
                    icon: "gauge.with.dots.needle.67percent",
                    label: "Speed",
                    value: clip.speed,
                    range: 0.25...4.0,
                    displayMultiplier: 1,
                    valueSuffix: "x",
                    format: "%.2f",
                    onChanged: { newVal in
                        editor.applyClipSpeed(clipId: clip.id, newSpeed: newVal)
                    }
                ) { newVal in
                    editor.commitClipSpeed(clipId: clip.id, newSpeed: newVal)
                }
            }
            .padding(AppTheme.Spacing.lg)
        }
    }

    // MARK: - Frame Section

    @ViewBuilder
    private func frameSection(_ clip: Clip) -> some View {
        let tl = clip.transform.topLeft
        let canvasW = Double(editor.timeline.width)
        let canvasH = Double(editor.timeline.height)

        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            HStack {
                Image(systemName: "crop")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Text("Frame")
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
                Button {
                    editor.commitClipProperty(clipId: clip.id) { $0.transform = Transform() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .buttonStyle(.plain)
                .help("Reset transform")
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                InspectorNumberField(label: "X", value: tl.x * canvasW) { newX in
                    editor.commitClipProperty(clipId: clip.id) {
                        let old = $0.transform.topLeft
                        $0.transform = Transform(topLeft: (newX / canvasW, old.y), width: $0.transform.width, height: $0.transform.height)
                    }
                }
                InspectorNumberField(label: "Y", value: tl.y * canvasH) { newY in
                    editor.commitClipProperty(clipId: clip.id) {
                        let old = $0.transform.topLeft
                        $0.transform = Transform(topLeft: (old.x, newY / canvasH), width: $0.transform.width, height: $0.transform.height)
                    }
                }
                InspectorNumberField(label: "Scale", value: clip.transform.width * 100) { newScale in
                    editor.commitClipProperty(clipId: clip.id) {
                        let s = max(newScale, 1) / 100.0
                        let old = $0.transform.topLeft
                        let cx = old.x + $0.transform.width / 2.0
                        let cy = old.y + $0.transform.height / 2.0
                        $0.transform = Transform(topLeft: (cx - s / 2.0, cy - s / 2.0), width: s, height: s)
                    }
                }
            }
        }
    }

    // MARK: - Media Asset Inspector

    @ViewBuilder
    private func mediaAssetInspectorContent(_ asset: MediaAsset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                if asset.generationInput == nil {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text(asset.name)
                            .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .lineLimit(2)

                        metadataRow("Type", value: asset.type.trackLabel)

                        if asset.type != .audio {
                            if let size = imageDimensions(for: asset.url) {
                                metadataRow("Dimensions", value: "\(size.width) × \(size.height)")
                            }
                        }

                        if asset.duration > 0 && asset.type != .image {
                            metadataRow("Duration", value: formatDuration(asset.duration))
                        }

                        if let fileSize = fileSize(for: asset.url) {
                            metadataRow("File Size", value: fileSize)
                        }
                    }
                }

                if let gen = asset.generationInput {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        HStack(spacing: AppTheme.Spacing.xs) {
                            Text("AI Generated")
                                .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                                .foregroundStyle(AppTheme.Text.primaryColor)
                            Image(systemName: "sparkles")
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(.purple)
                        }

                        metadataRow("Model", value: modelDisplayName(for: gen.model))
                        metadataRow("Aspect Ratio", value: gen.aspectRatio)

                        if let resolution = gen.resolution {
                            metadataRow("Resolution", value: resolution)
                        }

                        if gen.duration > 0 {
                            metadataRow("Gen Duration", value: "\(gen.duration)s")
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Prompt")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                            Text(gen.prompt)
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.secondaryColor)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(AppTheme.Spacing.lg)
        }
    }

    private func metadataRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Spacer()
            Text(value)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(AppTheme.Border.subtleColor)
            .frame(height: 0.5)
    }

    // MARK: - Helpers

    private var selectedClip: Clip? {
        guard editor.selectedClipIds.count == 1,
              let id = editor.selectedClipIds.first else { return nil }
        for track in editor.timeline.tracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
    }

    private var selectedMediaAsset: MediaAsset? {
        guard editor.selectedMediaAssetIds.count == 1,
              let id = editor.selectedMediaAssetIds.first else { return nil }
        return editor.mediaAssets.first { $0.id == id }
    }

    private func modelDisplayName(for modelId: String) -> String {
        if let config = ImageModelConfig.allModels.first(where: { $0.id == modelId }) {
            return config.displayName
        }
        if let config = VideoModelConfig.allModels.first(where: { $0.id == modelId }) {
            return config.displayName
        }
        return modelId
    }

    private func fileSize(for url: URL) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let bytes = attrs[.size] as? Int64 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func imageDimensions(for url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frac = Int((seconds.truncatingRemainder(dividingBy: 1)) * 100)
        if mins > 0 {
            return String(format: "%d:%02d.%02d", mins, secs, frac)
        }
        return String(format: "%d.%02ds", secs, frac)
    }
}

// MARK: - Inspector Slider

private struct InspectorSlider: View {
    let icon: String
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let displayMultiplier: Double
    let valueSuffix: String
    let format: String
    var onChanged: ((Double) -> Void)? = nil
    let onCommit: (Double) -> Void

    @State private var liveValue: Double = 0
    @State private var isDragging = false

    private var displayValue: Double { (isDragging ? liveValue : value) * displayMultiplier }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
                Text(String(format: format, displayValue) + valueSuffix)
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }

            Slider(value: $liveValue, in: range) { editing in
                if editing {
                    isDragging = true
                } else {
                    isDragging = false
                    onCommit(liveValue)
                }
            }
            .controlSize(.small)
        }
        .onAppear { liveValue = value }
        .onChange(of: value) { _, newValue in
            if !isDragging { liveValue = newValue }
        }
        .onChange(of: liveValue) { _, newValue in
            if isDragging { onChanged?(newValue) }
        }
    }
}

// MARK: - Inspector Number Field

private struct InspectorNumberField: View {
    let label: String
    let value: Double
    let onCommit: (Double) -> Void

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.md).monospacedDigit())
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(Color.white.opacity(0.06))
                )
                .focused($isFocused)
                .onSubmit { commitValue() }
                .onChange(of: isFocused) { _, focused in
                    if !focused { commitValue() }
                }
        }
        .onAppear { text = String(Int(value.rounded())) }
        .onChange(of: value) { _, newValue in
            if !isFocused { text = String(Int(newValue.rounded())) }
        }
    }

    private func commitValue() {
        if let parsed = Double(text) {
            onCommit(parsed)
        } else {
            text = String(Int(value.rounded()))
        }
    }
}
