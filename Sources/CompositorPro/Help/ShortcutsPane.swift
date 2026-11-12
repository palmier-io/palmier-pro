import SwiftUI

struct ShortcutsPane: View {
    private static let allShortcuts: [ShortcutGroup] = [
        ShortcutGroup(title: L10n.string("Playback"), shortcuts: [
            ("Space", L10n.string("Play / Pause")),
            ("←", L10n.string("Step Backward")),
            ("→", L10n.string("Step Forward")),
            ("Shift + ←", L10n.string("Skip Backward")),
            ("Shift + →", L10n.string("Skip Forward")),
        ]),
        ShortcutGroup(title: L10n.string("Tools"), shortcuts: [
            ("V", L10n.string("Selection Tool")),
            ("C", L10n.string("Razor Tool")),
        ]),
        ShortcutGroup(title: L10n.string("Editing"), shortcuts: [
            ("A", L10n.string("Select Forward on Track")),
            ("Shift + A", L10n.string("Select Forward on All Tracks")),
            ("Cmd + K", L10n.string("Split at Playhead")),
            ("[ or Q", L10n.string("Trim Start to Playhead")),
            ("] or W", L10n.string("Trim End to Playhead")),
            ("Backspace", L10n.string("Delete")),
            ("Shift + Backspace", L10n.string("Ripple Delete")),
            ("Shift + Drag Edge", L10n.string("Ripple Trim")),
            ("Cmd + Drag Media", L10n.string("Ripple Insert")),
            ("Opt + Drag", L10n.string("Duplicate Clip")),
        ]),
        ShortcutGroup(title: L10n.string("Timeline"), shortcuts: [
            ("Shift + Drag Ruler", L10n.string("Select Range")),
            ("Drag Range Edge", L10n.string("Adjust Range")),
            ("I", L10n.string("Mark Range Start")),
            ("O", L10n.string("Mark Range End")),
            ("Opt + Scroll", L10n.string("Zoom to Cursor")),
            ("Pinch", L10n.string("Zoom to Cursor")),
            ("Cmd + Scroll", L10n.string("Scroll Horizontally")),
        ]),
        ShortcutGroup(title: L10n.string("File"), shortcuts: [
            ("Cmd + N", L10n.string("New")),
            ("Cmd + Shift + N", L10n.string("New Folder")),
            ("Cmd + O", L10n.string("Open")),
            ("Cmd + S", L10n.string("Save")),
            ("Cmd + Shift + S", L10n.string("Save As")),
            ("Cmd + I", L10n.string("Import Media")),
            ("Cmd + E", L10n.string("Export")),
        ]),
        ShortcutGroup(title: L10n.string("Edit"), shortcuts: [
            ("Cmd + Z", L10n.string("Undo")),
            ("Cmd + Shift + Z", L10n.string("Redo")),
            ("Cmd + X", L10n.string("Cut")),
            ("Cmd + C", L10n.string("Copy")),
            ("Cmd + V", L10n.string("Paste")),
            ("Cmd + A", L10n.string("Select All")),
        ]),
        ShortcutGroup(title: L10n.string("View"), shortcuts: [
            ("Cmd + F", L10n.string("Full Screen")),
            ("`", L10n.string("Maximize Focused Panel")),
            ("Cmd + Scroll", L10n.string("Zoom Preview to Cursor")),
            ("Esc", L10n.string("Deselect & Reset Tool")),
        ]),
    ]

    private static let leftColumn = Array(allShortcuts.prefix(4))
    private static let rightColumn = Array(allShortcuts.dropFirst(4))

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: AppTheme.Spacing.xlXxl) {
                shortcutColumn(groups: Self.leftColumn)
                shortcutColumn(groups: Self.rightColumn)
            }
            .frame(maxWidth: AppTheme.Settings.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.bottom, AppTheme.Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollEdgeEffectStyle(.soft, for: .top)
    }

    private func shortcutColumn(groups: [ShortcutGroup]) -> some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: AppTheme.Spacing.md,
            verticalSpacing: AppTheme.Spacing.sm
        ) {
            ForEach(Array(groups.enumerated()), id: \.element.title) { index, group in
                if index > 0 {
                    Color.clear
                        .frame(height: AppTheme.Spacing.md)
                        .gridCellColumns(2)
                }

                Text(group.title)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .gridCellColumns(2)

                ForEach(group.shortcuts, id: \.0) { shortcut, description in
                    GridRow(alignment: .firstTextBaseline) {
                        Text(shortcut)
                            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.regular, design: .monospaced))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                            .fixedSize()

                        Text(description)
                            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.regular))
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ShortcutGroup {
    let title: String
    let shortcuts: [(String, String)]
}

#Preview {
    ShortcutsPane()
        .frame(width: AppTheme.Settings.contentMaxWidth, height: AppTheme.Settings.skillDetailMinHeight)
        .background(AppTheme.Background.surfaceColor)
}
