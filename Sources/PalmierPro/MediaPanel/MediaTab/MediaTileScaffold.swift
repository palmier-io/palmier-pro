import SwiftUI

/// Shared grid-tile chrome: artwork, selection border, name row with rename, clicks, context menu.
struct MediaTileScaffold<Artwork: View, MenuItems: View>: View {
    let name: String
    let isSelected: Bool
    var isDropHover: Bool = false
    var showsActiveDot: Bool = false
    @Binding var isRenaming: Bool
    let onTap: () -> Void
    let onOpen: () -> Void
    let onCommitRename: (String) -> Void
    let onCancelRename: () -> Void
    @ViewBuilder let artwork: () -> Artwork
    @ViewBuilder let menuItems: () -> MenuItems

    @State private var lastClickTime: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ZStack { artwork() }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .strokeBorder(borderColor, lineWidth: borderWidth)
                )
                .contentShape(Rectangle())

            nameRow
                .padding(.horizontal, AppTheme.Spacing.xs)
                .padding(.vertical, AppTheme.Spacing.xxs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                        .fill(isRenaming ? Color.white.opacity(AppTheme.Opacity.faint) : .clear)
                )
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { handleClick() }
        .contextMenu { menuItems() }
    }

    @ViewBuilder
    private var nameRow: some View {
        if isRenaming {
            InlineRenameField(
                originalName: name,
                onCommit: onCommitRename,
                onCancel: onCancelRename
            )
        } else {
            HStack(spacing: AppTheme.Spacing.xs) {
                if showsActiveDot {
                    Circle()
                        .fill(AppTheme.Accent.primary)
                        .frame(width: AppTheme.Spacing.xs, height: AppTheme.Spacing.xs)
                }
                Text(name)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(AppTheme.Text.primaryColor)
            }
        }
    }

    private var borderColor: Color {
        if isDropHover { return AppTheme.Accent.primary.opacity(AppTheme.Opacity.prominent) }
        if isSelected { return AppTheme.Accent.primary }
        return Color.clear
    }

    private var borderWidth: CGFloat {
        isDropHover || isSelected ? AppTheme.BorderWidth.thick : 0
    }

    private func handleClick() {
        let now = Date()
        if let last = lastClickTime, now.timeIntervalSince(last) < NSEvent.doubleClickInterval {
            onOpen()
            lastClickTime = nil
        } else {
            onTap()
            lastClickTime = now
        }
    }
}

extension View {
    func tileBadge() -> some View {
        foregroundStyle(.white)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(.ultraThinMaterial, in: .capsule)
            .padding(AppTheme.Spacing.xs)
    }
}
