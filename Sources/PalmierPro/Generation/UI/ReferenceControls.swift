import SwiftUI

private struct ReferenceAssetPreview: View {
    let asset: MediaAsset

    var body: some View {
        ZStack {
            Color.black
            if let thumbnail = asset.thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: asset.type.sfSymbolName)
                    .font(.system(size: AppTheme.FontSize.xl))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(asset.name), \(asset.type.trackLabel)")
    }
}

/// Thumbnail tile for a reference asset with an optional @-tag badge and remove button.
struct RefCard: View {
    let asset: MediaAsset
    var tag: String? = nil
    let onRemove: () -> Void

    var body: some View {
        ReferenceAssetPreview(asset: asset)
            .frame(width: AppTheme.GenerationPanel.referenceTileWidth, height: AppTheme.GenerationPanel.referenceTileHeight)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin))
            .overlay(alignment: .bottomLeading) {
                if let tag {
                    Text(tag)
                        .font(.system(size: AppTheme.FontSize.xxs, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .padding(.horizontal, AppTheme.Spacing.xs)
                        .padding(.vertical, AppTheme.Spacing.xxs)
                        .background(Color.black.opacity(AppTheme.Opacity.strong), in: Capsule())
                        .padding(AppTheme.Spacing.xs)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button { onRemove() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppTheme.FontSize.smMd))
                        .foregroundStyle(.white.opacity(AppTheme.Opacity.prominent))
                        .shadow(radius: 2)
                        .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(asset.name)")
            }
    }
}

/// Dashed drop tile; delivers dragged media assets of the accepted types.
struct RefDropZone: View {
    @Environment(EditorViewModel.self) private var editor
    @Binding var isTargeted: Bool
    var accepting: Set<ClipType> = [.image]
    var iconName: String = "photo.badge.plus"
    let onDrop: (MediaAsset) -> Void

    var body: some View {
        Image(systemName: iconName)
            .font(.system(size: AppTheme.FontSize.smMd))
            .foregroundStyle(isTargeted ? AppTheme.Accent.primary : AppTheme.Text.mutedColor)
            .frame(width: AppTheme.GenerationPanel.referenceTileWidth, height: AppTheme.GenerationPanel.referenceTileHeight)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(isTargeted ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.faint) : Color.white.opacity(AppTheme.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        isTargeted ? AppTheme.Accent.primary.opacity(AppTheme.Opacity.strong) : AppTheme.Border.primaryColor,
                        style: StrokeStyle(lineWidth: AppTheme.BorderWidth.thin, dash: [4, 3])
                    )
            )
            .overlay {
                DropTargetOverlay(isTargeted: $isTargeted) { payload in
                    for asset in editor.assetsFromDragPayload(payload)
                    where accepting.contains(asset.type) {
                        onDrop(asset)
                    }
                }
            }
    }
}

/// Labeled single-asset slot: shows the asset thumbnail or a drop zone that
/// reports type mismatches through onError.
struct FrameSlot: View {
    let label: String
    let asset: MediaAsset?
    @Binding var isTargeted: Bool
    var accepting: Set<ClipType> = [.image]
    var iconName: String = "photo.badge.plus"
    let onDrop: (MediaAsset) -> Void
    let onClear: () -> Void
    let onError: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            if let asset {
                ReferenceAssetPreview(asset: asset)
                    .frame(width: AppTheme.GenerationPanel.referenceTileWidth, height: AppTheme.GenerationPanel.referenceTileHeight)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                    .overlay(RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin))
                    .overlay(alignment: .topTrailing) {
                        Button { onClear() } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: AppTheme.FontSize.smMd))
                                .foregroundStyle(.white.opacity(AppTheme.Opacity.prominent))
                                .shadow(radius: 2)
                                .frame(width: AppTheme.IconSize.smMd, height: AppTheme.IconSize.smMd)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(asset.name)")
                    }
            } else {
                RefDropZone(
                    isTargeted: $isTargeted,
                    accepting: Set(ClipType.allCases),
                    iconName: iconName
                ) { dropped in
                    if accepting.contains(dropped.type) {
                        onDrop(dropped)
                    } else {
                        let kinds = accepting.map(\.rawValue).sorted().joined(separator: " or ")
                        onError("Drop \(kinds) here.")
                    }
                }
            }
        }
    }
}
