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
    let shouldAutoFocus: Bool
    let onAutoFocusConsumed: () -> Void

    @State private var renameDraft: String = ""
    @FocusState private var isRenameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            ZStack {
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color(white: 1.0, opacity: AppTheme.Opacity.subtle))
                Image(systemName: "folder.fill")
                    .font(.system(size: AppTheme.FontSize.display, weight: .light))
                    .foregroundStyle(Color.accentColor.opacity(0.85))
                if childCount > 0 {
                    VStack {
                        HStack {
                            Spacer()
                            Text("\(childCount)")
                                .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                                .foregroundStyle(.white)
                                .monospacedDigit()
                                .padding(.horizontal, AppTheme.Spacing.sm)
                                .padding(.vertical, AppTheme.Spacing.xxs)
                                .background(.ultraThinMaterial, in: .capsule)
                                .padding(AppTheme.Spacing.xs)
                        }
                        Spacer()
                    }
                }
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .strokeBorder(
                        borderColor,
                        lineWidth: borderWidth
                    )
            )
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onOpen() }

            ZStack(alignment: .leading) {
                if isRenaming {
                    TextField("Folder", text: $renameDraft)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .textFieldStyle(.plain)
                        .lineLimit(1)
                        .focused($isRenameFieldFocused)
                        .onSubmit { commit() }
                        .onChange(of: isRenameFieldFocused) { _, focused in
                            if !focused { commit() }
                        }
                        .onExitCommand { onCancelRename() }
                } else {
                    Text(folder.name)
                        .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(AppTheme.Text.primaryColor)
                        .onTapGesture(count: 2) { beginRename() }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(isRenaming ? Color.white.opacity(AppTheme.Opacity.faint) : .clear)
            )
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu { contextMenuItems }
        .onAppear {
            if shouldAutoFocus {
                renameDraft = folder.name
                isRenameFieldFocused = true
                onAutoFocusConsumed()
            }
        }
        .onChange(of: isRenaming) { _, newValue in
            if newValue {
                renameDraft = folder.name
                DispatchQueue.main.async { isRenameFieldFocused = true }
            }
        }
    }

    private var borderColor: Color {
        if isDropHover { return Color.accentColor.opacity(0.8) }
        if isSelected { return Color.accentColor }
        return Color.clear
    }

    private var borderWidth: CGFloat {
        if isDropHover { return AppTheme.BorderWidth.thick }
        if isSelected { return AppTheme.BorderWidth.thick }
        return 0
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button("Open") { onOpen() }
        Button("Rename") { beginRename() }
        Divider()
        Button("Delete", role: .destructive) { onDelete() }
    }

    private func beginRename() {
        renameDraft = folder.name
        isRenaming = true
    }

    private func commit() {
        guard isRenaming else { return }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == folder.name {
            onCancelRename()
        } else {
            onCommitRename(trimmed)
        }
    }
}
