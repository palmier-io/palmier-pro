import SwiftUI

/// Named caption-style gallery grouped Loud / On a box / Calm. Cells render the
/// same `TextFrameRenderer` the compositor uses; tapping writes the selection
/// onto the project's persisted caption style.
struct CaptionStyleGallery: View {
    @Binding var selection: String?
    @Environment(\.displayScale) private var displayScale

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: AppTheme.Spacing.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            ForEach(CaptionStyle.Group.allCases, id: \.self) { group in
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text(label(group))
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        ForEach(CaptionStyles.all.filter { $0.group == group }, id: \.id) { preset in
                            CaptionStyleCell(preset: preset, selected: selection == preset.id,
                                             displayScale: displayScale,
                                             onSelect: { selection = preset.id })
                        }
                    }
                }
            }
        }
    }

    private func label(_ group: CaptionStyle.Group) -> String {
        switch group {
        case .loud: return L10n.string("Loud")
        case .onBox: return L10n.string("On a box")
        case .calm: return L10n.string("Calm")
        }
    }
}

private struct CaptionStyleCell: View {
    let preset: CaptionStyle
    var selected: Bool
    var displayScale: CGFloat
    var onSelect: () -> Void

    @State private var hovering = false

    private static let sample = "Captions"
    private static let cell = CGSize(width: 96, height: 56)

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xxs) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Background.previewCanvasColor)
                if let img = previewImage {
                    Image(nsImage: img).interpolation(.high)
                }
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
        .onTapGesture(perform: onSelect)
        .help(preset.intent)
    }

    private var previewImage: NSImage? {
        let resolved = preset.resolved(canvasHeight: Int(Self.cell.height))
        let style = resolved.style
        let presetAnimation = CaptionPreviewRender.loopFrames(resolved.animation.preset)
        let clip = CaptionPreviewRender.clip(
            content: Self.sample, style: style,
            transform: Transform(centerX: 0.5, centerY: 0.5, width: 0.92, height: 0.5),
            preset: resolved.animation.preset, highlight: resolved.animation.highlight)
        let frame = hovering || selected ? presetAnimation - 1 : presetAnimation - 1
        return CaptionPreviewRender.nsImage(clip: clip, frame: frame, size: Self.cell, scale: max(1, displayScale))
    }
}
