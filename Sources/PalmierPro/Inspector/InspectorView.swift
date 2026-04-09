import SwiftUI

struct InspectorView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        Group {
            if let clip = selectedClip {
                inspectorContent(clip)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Content

    @ViewBuilder
    private func inspectorContent(_ clip: Clip) -> some View {
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

    // MARK: - Helpers

    private var selectedClip: Clip? {
        guard editor.selectedClipIds.count == 1,
              let id = editor.selectedClipIds.first else { return nil }
        for track in editor.timeline.tracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
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
