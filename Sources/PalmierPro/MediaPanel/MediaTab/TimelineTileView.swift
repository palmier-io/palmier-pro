import SwiftUI

struct TimelineTileView: View {
    let timeline: Timeline
    let posterImage: NSImage?
    let isSelected: Bool
    let isActive: Bool
    let canDelete: Bool
    @Binding var isRenaming: Bool
    let onTap: () -> Void
    let onOpen: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        MediaTileScaffold(
            name: timeline.name,
            isSelected: isSelected,
            showsActiveDot: isActive,
            isRenaming: $isRenaming,
            onTap: onTap,
            onOpen: onOpen,
            onCommitRename: onCommitRename,
            onCancelRename: onCancelRename
        ) {
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Interaction.fill(AppTheme.Opacity.subtle))
            if let posterImage {
                GeometryReader { geo in
                    Image(nsImage: posterImage)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
            } else {
                Image(systemName: "film.stack")
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.light))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            if timeline.totalFrames > 0 {
                durationBadge
            }
            if posterImage != nil {
                timelineBadge
            }
        } menuItems: {
            Button(L10n.string("Open")) { onOpen() }
            Button(L10n.string("Rename")) { isRenaming = true }
            Button(L10n.string("Duplicate")) { onDuplicate() }
            Divider()
            Button(L10n.string("Delete"), role: .destructive) { onDelete() }
                .disabled(!canDelete)
        }
    }

    // Matches AssetThumbnailView: type badge top-leading, duration bottom-trailing.
    private var timelineBadge: some View {
        VStack {
            HStack {
                Image(systemName: "film.stack")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .tileBadge()
                    .foregroundStyle(isActive
                        ? AppTheme.MediaOverlay.primaryColor
                        : AppTheme.MediaOverlay.secondaryColor)
                Spacer()
            }
            Spacer()
        }
    }

    private var durationBadge: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                Text(formatTimecode(frame: timeline.totalFrames, fps: timeline.fps))
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.medium))
                    .monospacedDigit()
                    .tileBadge()
            }
        }
    }
}
