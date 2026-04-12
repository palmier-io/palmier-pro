import SwiftUI

struct InspectorView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        Group {
            if let clip = selectedClip {
                clipInspectorContent(clip)
            } else if let asset = selectedMediaAsset {
                mediaAssetInspectorContent(asset)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Clip Inspector

    @ViewBuilder
    private func clipInspectorContent(_ clip: Clip) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                // Clip info
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(editor.mediaResolver.displayName(for: clip.mediaRef))
                        .font(.system(size: AppTheme.FontSize.lg, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .lineLimit(1)
                    Text("Start: \(formatTimecode(frame: clip.startFrame, fps: editor.timeline.fps))")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text("Duration: \(formatTimecode(frame: clip.durationFrames, fps: editor.timeline.fps))")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }

                Rectangle()
                    .fill(AppTheme.Border.subtleColor)
                    .frame(height: 0.5)

                // Speed
                propertySlider("Speed", value: clip.speed, range: 0.25...4.0, format: "%.2fx") { newVal in
                    editor.updateClipProperty(clipId: clip.id) { $0.speed = newVal }
                }

                // Volume
                propertySlider("Volume", value: clip.volume, range: 0...1, format: "%.0f%%", displayMultiplier: 100) { newVal in
                    editor.updateClipProperty(clipId: clip.id) { $0.volume = newVal }
                }

                // Opacity
                propertySlider("Opacity", value: clip.opacity, range: 0...1, format: "%.0f%%", displayMultiplier: 100) { newVal in
                    editor.updateClipProperty(clipId: clip.id) { $0.opacity = newVal }
                }

                Rectangle()
                    .fill(AppTheme.Border.subtleColor)
                    .frame(height: 0.5)

                // Transform
                Text("Transform")
                    .font(.system(size: AppTheme.FontSize.md, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)

                propertySlider("X", value: clip.transform.x, range: 0...1, format: "%.2f") { newVal in
                    editor.updateClipProperty(clipId: clip.id) { $0.transform.x = newVal }
                }
                propertySlider("Y", value: clip.transform.y, range: 0...1, format: "%.2f") { newVal in
                    editor.updateClipProperty(clipId: clip.id) { $0.transform.y = newVal }
                }
                propertySlider("Width", value: clip.transform.width, range: 0...2, format: "%.2f") { newVal in
                    editor.updateClipProperty(clipId: clip.id) { $0.transform.width = newVal }
                }
                propertySlider("Height", value: clip.transform.height, range: 0...2, format: "%.2f") { newVal in
                    editor.updateClipProperty(clipId: clip.id) { $0.transform.height = newVal }
                }
            }
            .padding(AppTheme.Spacing.lg)
        }
    }

    // MARK: - Slider component

    private func propertySlider(
        _ label: String,
        value: Double,
        range: ClosedRange<Double>,
        format: String,
        displayMultiplier: Double = 1,
        onCommit: @escaping (Double) -> Void
    ) -> some View {
        PropertySlider(
            label: label,
            value: value,
            range: range,
            format: format,
            displayMultiplier: displayMultiplier,
            onCommit: onCommit
        )
    }

    // MARK: - Media Asset Inspector

    @ViewBuilder
    private func mediaAssetInspectorContent(_ asset: MediaAsset) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
                // Asset info
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

                if let gen = asset.generationInput {
                    Rectangle()
                        .fill(AppTheme.Border.subtleColor)
                        .frame(height: 0.5)

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
                                .lineLimit(10)
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

/// Slider that only commits undo on release, not during drag.
private struct PropertySlider: View {
    let label: String
    let value: Double
    let range: ClosedRange<Double>
    let format: String
    let displayMultiplier: Double
    let onCommit: (Double) -> Void

    @State private var liveValue: Double = 0
    @State private var isDragging = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Spacer()
                Text(String(format: format, displayValue * displayMultiplier))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            Slider(value: $liveValue, in: range) { editing in
                if editing {
                    isDragging = true
                } else {
                    isDragging = false
                    onCommit(liveValue)
                }
            }
            .controlSize(.mini)
        }
        .onAppear { liveValue = value }
        .onChange(of: value) { _, newValue in
            if !isDragging { liveValue = newValue }
        }
    }

    private var displayValue: Double { isDragging ? liveValue : value }
}
