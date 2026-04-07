import SwiftUI

struct AssetThumbnailView: View {
    let asset: MediaAsset

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

            Text(asset.name)
                .font(.system(size: AppTheme.FontSize.xs))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .frame(maxWidth: .infinity)
    }

    private var iconName: String { asset.type.sfSymbolName }
}
