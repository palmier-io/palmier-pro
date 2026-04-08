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
                    .strokeBorder(Color(nsColor: asset.type.themeColor), lineWidth: isOnTimeline ? 2 : 0)
            )

            Text(asset.name)
                .font(.system(size: AppTheme.FontSize.xs))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isOnTimeline ? Color(nsColor: asset.type.themeColor) : AppTheme.Text.secondaryColor)
        }
        .frame(maxWidth: .infinity)
    }

    private var iconName: String { asset.type.sfSymbolName }

    private var isOnTimeline: Bool {
        let mediaRef = asset.url.lastPathComponent
        return editor.timeline.tracks.contains { track in
            track.clips.contains { $0.mediaRef == mediaRef }
        }
    }
}
