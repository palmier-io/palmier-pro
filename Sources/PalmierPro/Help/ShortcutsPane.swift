import SwiftUI

struct ShortcutsPane: View {
    private static let allShortcuts: [ShortcutGroup] = [
        ShortcutGroup(title: "Playback", shortcuts: [
            ("Space", "Play / Pause"),
            ("←", "Step Backward"),
            ("→", "Step Forward"),
            ("Shift + ←", "Skip Backward"),
            ("Shift + →", "Skip Forward"),
        ]),
        ShortcutGroup(title: "Tools", shortcuts: [
            ("V", "Selection Tool"),
            ("C", "Razor Tool"),
        ]),
        ShortcutGroup(title: "Editing", shortcuts: [
            ("A", "Select Forward on Track"),
            ("Shift + A", "Select Forward on All Tracks"),
            ("Cmd + K", "Split at Playhead"),
            ("[ or Q", "Trim Start to Playhead"),
            ("] or W", "Trim End to Playhead"),
            ("Backspace", "Delete"),
            ("Shift + Backspace", "Ripple Delete"),
            ("Shift + Drag Edge", "Ripple Trim"),
            ("Cmd + Drag Media", "Ripple Insert"),
            ("Opt + Drag", "Duplicate Clip"),
        ]),
        ShortcutGroup(title: "Timeline", shortcuts: [
            ("Shift + Drag Ruler", "Select Range"),
            ("Drag Range Edge", "Adjust Range"),
            ("I", "Mark Range Start"),
            ("O", "Mark Range End"),
            ("Opt + Scroll", "Zoom to Cursor"),
            ("Pinch", "Zoom to Cursor"),
            ("Cmd + Scroll", "Scroll Horizontally"),
        ]),
        ShortcutGroup(title: "File", shortcuts: [
            ("Cmd + N", "New"),
            ("Cmd + O", "Open"),
            ("Cmd + S", "Save"),
            ("Cmd + Shift + S", "Save As"),
            ("Cmd + I", "Import Media"),
            ("Cmd + E", "Export"),
        ]),
        ShortcutGroup(title: "Edit", shortcuts: [
            ("Cmd + Z", "Undo"),
            ("Cmd + Shift + Z", "Redo"),
            ("Cmd + X", "Cut"),
            ("Cmd + C", "Copy"),
            ("Cmd + V", "Paste"),
            ("Cmd + A", "Select All"),
        ]),
        ShortcutGroup(title: "View", shortcuts: [
            ("Cmd + F", "Full Screen"),
            ("`", "Maximize Focused Panel"),
            ("Cmd + Scroll", "Zoom Preview to Cursor"),
            ("Esc", "Deselect & Reset Tool"),
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
