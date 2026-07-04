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
                .fill(Color(white: 1.0, opacity: AppTheme.Opacity.subtle))
            Image(systemName: "folder.fill")
                .font(.system(size: AppTheme.FontSize.display, weight: AppTheme.FontWeight.light))
                .foregroundStyle(AppTheme.Accent.primary.opacity(AppTheme.Opacity.prominent))
            if childCount > 0 {
                countBadge
            }
        } menuItems: {
            Button("Open") { onOpen() }
            Button("Rename") { isRenaming = true }
            Divider()
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private var countBadge: some View {
        VStack {
            HStack {
                Spacer()
                Text("\(childCount)")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: AppTheme.FontWeight.semibold))
                    .monospacedDigit()
                    .tileBadge()
            }
            Spacer()
        }
    }
}
