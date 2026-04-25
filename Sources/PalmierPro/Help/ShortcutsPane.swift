import SwiftUI

struct ShortcutsPane: View {
    private static let shortcutKeyColumnWidth: CGFloat = 118

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
            ("Cmd + K", "Split at Playhead"),
            ("[ or Q", "Trim Start to Playhead"),
            ("] or W", "Trim End to Playhead"),
            ("Backspace", "Delete"),
            ("Shift + Backspace", "Ripple Delete"),
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

    private static let leftColumn = Array(allShortcuts.prefix(3))
    private static let rightColumn = Array(allShortcuts.dropFirst(3))

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            shortcutColumn(groups: Self.leftColumn)
            shortcutColumn(groups: Self.rightColumn)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func shortcutColumn(groups: [ShortcutGroup]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(groups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .textCase(.uppercase)
                        .tracking(0.3)

                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(group.shortcuts, id: \.0) { shortcut, description in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(shortcut)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(AppTheme.Text.primaryColor)
                                    .fontWeight(.semibold)
                                    .frame(width: Self.shortcutKeyColumnWidth, alignment: .leading)

                                Text(description)
                                    .font(.system(size: 11))
                                    .foregroundStyle(AppTheme.Text.secondaryColor)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
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
        .frame(width: 700, height: 520)
        .background(AppTheme.Background.surfaceColor)
}
