import SwiftUI

struct FolderTileView: View {
    let folder: MediaFolder
    let isSelected: Bool
    let isDropHover: Bool
    let childCount: Int
    @Binding var isRenaming: Bool
    let onTap: () -> Void
    let onOpen: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        MediaTileScaffold(
            name: folder.name,
            isSelected: isSelected,
            isDropHover: isDropHover,
            isRenaming: $isRenaming,
            onTap: onTap,
            onOpen: onOpen,
            onCommitRename: onCommitRename,
            onCancelRename: onCancelRename
        ) {
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(AppTheme.Interaction.fill(AppTheme.Opacity.subtle))
            Image(systemName: "folder.fill")
                .font(.system(size: AppTheme.FontSize.display, weight: AppTheme.FontWeight.light))
                .foregroundStyle(AppTheme.Accent.primary.opacity(AppTheme.Opacity.prominent))
            if childCount > 0 {
                countBadge
            }
        } menuItems: {
            Button(L10n.string("Open")) { onOpen() }
            Button(L10n.string("Rename")) { isRenaming = true }
            Divider()
            Button(L10n.string("Delete"), role: .destructive) { onDelete() }
        }
    }

    private var countBadge: some View {
        VStack {
            HStack {
                Spacer()
                Text(verbatim: "\(childCount)")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .monospacedDigit()
                    .tileBadge()
            }
            Spacer()
        }
    }
}
