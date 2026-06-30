import SwiftUI

/// Visual preset picker: a grid of cells that animate the preset on hover or when selected,
/// rendered by the same TextFrameRenderer the compositor uses.
struct CaptionPresetGallery: View {
    @Binding var selection: TextAnimation.Preset
    var highlight: TextStyle.RGBA? = nil

    private let columns = [GridItem(.adaptive(minimum: 84), spacing: AppTheme.Spacing.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            section("Per line", [.none] + TextAnimation.Preset.perLine)
            section("Per word", TextAnimation.Preset.perWord)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ presets: [TextAnimation.Preset]) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text(title)
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.sm) {
                ForEach(presets, id: \.self) { preset in
                    CaptionPresetCell(preset: preset, selected: selection == preset, highlight: highlight)
                        .onTapGesture { selection = preset }
                }
            }
        }
    }
}

private struct CaptionPresetCell: View {
    let preset: TextAnimation.Preset
    let selected: Bool
    var highlight: TextStyle.RGBA? = nil

    @State private var hovering = false
    @State private var start = Date()
    @Environment(\.displayScale) private var displayScale

    private static let sample = "Aa Bb Cc"
    private static let cell = CGSize(width: 84, height: 48)
    private static let fps = 30
    private var loopFrames: Int { CaptionPreviewRender.loopFrames(preset) }

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xxs) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Background.previewCanvasColor)
                content
            }
            .frame(width: Self.cell.width, height: Self.cell.height)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        selected ? AppTheme.Accent.timecodeColor : AppTheme.Border.subtleColor,
                        lineWidth: selected ? AppTheme.BorderWidth.medium : AppTheme.BorderWidth.hairline)
            )
            Text(preset.displayName)
                .font(.system(size: AppTheme.FontSize.xxs, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var content: some View {
        // Animate on hover or when selected; otherwise a settled poster frame.
        if preset != .none, hovering || selected {
            SwiftUI.TimelineView(.periodic(from: start, by: 1.0 / Double(Self.fps))) { ctx in
                cellImage(frame: Int(ctx.date.timeIntervalSince(start) * Double(Self.fps)) % loopFrames)
            }
        } else {
            cellImage(frame: loopFrames - 1)
        }
    }

    @ViewBuilder private func cellImage(frame: Int) -> some View {
        if let img = CaptionPreviewRender.nsImage(clip: previewClip, frame: frame, size: Self.cell, scale: max(1, displayScale)) {
            Image(nsImage: img).interpolation(.high)
        } else {
            Color.clear
        }
    }

    private var previewClip: Clip {
        var style = TextStyle()
        style.color = .init(r: 1, g: 1, b: 1, a: 1)
        style.shadow.enabled = false
        style.fontSize = 300   // fraction of render height; large so the sample reads in a small cell
        let transform = Transform(centerX: 0.5, centerY: 0.5, width: 0.92, height: 0.55)
        return CaptionPreviewRender.clip(content: Self.sample, style: style, transform: transform, preset: preset, highlight: highlight)
    }
}
