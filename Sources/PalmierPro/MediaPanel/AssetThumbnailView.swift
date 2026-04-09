import SwiftUI

struct AssetThumbnailView: View {
    let asset: MediaAsset
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            Group {
                if let thumbnail = asset.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Image(systemName: iconName)
                            .font(.title2)
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
            }
            .frame(height: 60)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color(nsColor: asset.type.themeColor),
                        lineWidth: isSelected ? 2.5 : (isOnTimeline ? 2 : 0)
                    )
            )
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            )

            Text(asset.name)
                .font(.system(size: AppTheme.FontSize.xs))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? Color.accentColor : (isOnTimeline ? Color(nsColor: asset.type.themeColor) : AppTheme.Text.secondaryColor))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture(count: 1) {
            let shiftHeld = NSEvent.modifierFlags.contains(.shift)
            if shiftHeld {
                if editor.selectedMediaAssetIds.contains(asset.id) {
                    editor.selectedMediaAssetIds.remove(asset.id)
                } else {
                    editor.selectedMediaAssetIds.insert(asset.id)
                }
            } else {
                editor.selectedMediaAssetIds = [asset.id]
            }
            editor.openPreviewTab(for: asset)
        }
    }

    private var iconName: String { asset.type.sfSymbolName }

    private var isSelected: Bool {
        editor.selectedMediaAssetIds.contains(asset.id)
    }

    private var isOnTimeline: Bool {
        editor.timeline.tracks.contains { track in
            track.clips.contains { $0.mediaRef == asset.id }
        }
    }
}
