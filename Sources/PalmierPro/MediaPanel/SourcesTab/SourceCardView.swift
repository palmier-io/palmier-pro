import SwiftUI

// One external-source asset. Click to import into the project library (background copy).
// iCloud-only / not-yet-local items are greyed and non-importable.
struct SourceCardView: View {
    let card: AssetCard
    var isImported: Bool = false
    let onImport: () -> Void

    @State private var isHovering = false

    private var thumbnailURL: URL? {
        card.thumbnailRef.flatMap { AssetProviderRegistry.provider(card.providerId)?.fetchURL(forRef: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ZStack {
                Rectangle().fill(Color.black)
                thumbnail
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .overlay(alignment: .bottomTrailing) { durationBadge }
            .overlay(alignment: .center) { if card.isLocal && !isImported { importAffordance } }
            .overlay(alignment: .topTrailing) { if isImported { importedBadge } }
            .overlay(alignment: .topLeading) { if !card.isLocal { icloudBadge } }
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
            )
            .opacity(card.isLocal ? 1 : AppTheme.Opacity.muted)
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            .onHover { h in withAnimation(.easeOut(duration: AppTheme.Anim.hover)) { isHovering = h } }
            .onTapGesture { if card.isLocal { onImport() } }
            .onDrag {
                guard card.isLocal else { return NSItemProvider() }
                return NSItemProvider(object: SourceDragPayload(card: card).encoded() as NSString)
            }
            .help(helpText)

            Text(card.name)
                .font(.system(size: AppTheme.FontSize.xs))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.horizontal, AppTheme.Spacing.xxs)
            if let desc = card.description {
                Text(desc)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.horizontal, AppTheme.Spacing.xxs)
            }
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = thumbnailURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image): image.resizable().scaledToFill()
                default: placeholderIcon
                }
            }
        } else {
            placeholderIcon
        }
    }

    private var placeholderIcon: some View {
        Image(systemName: card.type == .image ? "photo" : "film")
            .font(.system(size: AppTheme.FontSize.lg))
            .foregroundStyle(AppTheme.Text.tertiaryColor)
    }

    @ViewBuilder private var importAffordance: some View {
        if isHovering {
            Image(systemName: "square.and.arrow.down.fill")
                .font(.system(size: AppTheme.FontSize.lg, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(AppTheme.Spacing.sm)
                .background(Circle().fill(.black.opacity(AppTheme.Opacity.strong)))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var durationBadge: some View {
        if let ms = card.durationMs {
            Text(Self.formatDuration(ms))
                .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, AppTheme.Spacing.xxs)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: AppTheme.Radius.xs).fill(.black.opacity(AppTheme.Opacity.strong)))
                .padding(AppTheme.Spacing.xxs)
                .allowsHitTesting(false)
        }
    }

    private var helpText: String {
        if !card.isLocal { return "Not downloaded — fetch it in the source app first" }
        return isImported ? "Already in library — click to import again" : "Import into library"
    }

    private var importedBadge: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: AppTheme.FontSize.smMd))
            .foregroundStyle(.white, AppTheme.Status.successColor)
            .padding(AppTheme.Spacing.xxs)
    }

    private var icloudBadge: some View {
        Image(systemName: "icloud.and.arrow.down")
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(.white)
            .padding(AppTheme.Spacing.xxs)
            .background(Circle().fill(.black.opacity(AppTheme.Opacity.medium)))
            .padding(AppTheme.Spacing.xxs)
            .allowsHitTesting(false)
    }

    private static func formatDuration(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
