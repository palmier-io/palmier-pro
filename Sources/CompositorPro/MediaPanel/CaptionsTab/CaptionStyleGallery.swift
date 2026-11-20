import SwiftUI

/// Named caption-style gallery grouped Loud / On a box / Calm, filtered by social format (9:16 / 16:9).
/// Cells render the same `TextFrameRenderer` the compositor uses; tapping writes the selection
/// onto the project's persisted caption style.
struct CaptionStyleGallery: View {
    @Binding var selection: String?
    @State private var selectedFormat: SocialCaptionFormat = .all
    @Environment(\.displayScale) private var displayScale

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: AppTheme.Spacing.sm)]

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            // Social format filter pills
            HStack(spacing: AppTheme.Spacing.xs) {
                ForEach(SocialCaptionFormat.allCases, id: \.self) { format in
                    Button {
                        selectedFormat = format
                    } label: {
                        Text(formatLabel(format))
                            .font(.system(size: AppTheme.FontSize.xxs, weight: selectedFormat == format ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.regular))
                            .padding(.horizontal, AppTheme.Spacing.xs)
                            .padding(.vertical, AppTheme.Spacing.xxs)
                            .background(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                    .fill(selectedFormat == format ? AppTheme.Background.prominentColor : AppTheme.Background.surfaceColor)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                    .strokeBorder(selectedFormat == format ? AppTheme.Accent.timecodeColor : AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.hairline)
                            )
                            .foregroundStyle(selectedFormat == format ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            ForEach(CaptionStyle.Group.allCases, id: \.self) { group in
                let presetsInGroup = filteredPresets(group: group)
                if !presetsInGroup.isEmpty {
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                        Text(label(group))
                            .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.sm) {
                            ForEach(presetsInGroup, id: \.id) { preset in
                                CaptionStyleCell(
                                    preset: preset,
                                    badge: formatBadge(preset.id),
                                    selected: selection == preset.id,
                                    displayScale: displayScale,
                                    onSelect: { selection = preset.id }
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func formatLabel(_ format: SocialCaptionFormat) -> String {
        switch format {
        case .all: return L10n.string("All")
        case .vertical916: return L10n.string("Reels & TikTok (9:16)")
        case .horizontal169: return L10n.string("YouTube (16:9)")
        }
    }

    private func formatBadge(_ id: String) -> String? {
        CaptionTemplateLibrary.template(id: id)?.format.badgeLabel
    }

    private func filteredPresets(group: CaptionStyle.Group) -> [CaptionStyle] {
        CaptionStyles.all.filter { preset in
            guard preset.group == group else { return false }
            if selectedFormat == .all { return true }
            return CaptionTemplateLibrary.template(id: preset.id)?.format == selectedFormat
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
    var badge: String? = nil
    var selected: Bool
    var displayScale: CGFloat
    var onSelect: () -> Void

    @State private var hovering = false

    private static let sample = "Captions"
    private static let cell = CGSize(width: 96, height: 56)

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xxs) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(AppTheme.Background.previewCanvasColor)
                if let img = previewImage {
                    Image(nsImage: img).interpolation(.high)
                }
                if let badge {
                    Text(badge)
                        .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .padding(.horizontal, AppTheme.Spacing.xxs)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                                .fill(AppTheme.Background.surfaceColor.opacity(AppTheme.Opacity.prominent))
                        )
                        .padding(AppTheme.Spacing.xxs)
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
