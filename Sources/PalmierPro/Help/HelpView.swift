import SwiftUI

enum HelpTab: String, CaseIterable, Identifiable {
    case shortcuts = "Shortcuts"
    case mcp = "MCP"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .shortcuts: "keyboard"
        case .mcp: "network"
        }
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.25)
            HStack(spacing: 0) {
                sidebar
                Divider().opacity(0.25)
                detail
            }
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 520, idealHeight: 560)
    }

    private var header: some View {
        HStack {
            Text("Help")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
            Spacer()
            Button(action: { dismiss() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: 24, height: 24)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(HelpTab.allCases) { tab in
                sidebarRow(for: tab)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(width: 180, alignment: .top)
        .frame(maxHeight: .infinity)
    }

    private func sidebarRow(for tab: HelpTab) -> some View {
        let isActive = editor.helpTab == tab
        return Button(action: { editor.helpTab = tab }) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                Text(tab.rawValue)
                    .font(.system(size: AppTheme.FontSize.md, weight: isActive ? .medium : .regular))
                Spacer()
            }
            .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.sm)
            .contentShape(Rectangle())
            .hoverHighlight(isActive: isActive)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        switch editor.helpTab {
        case .shortcuts: ShortcutsPane()
        case .mcp: MCPInstructionsPane()
        }
    }
}

#Preview {
    HelpView()
        .environment(EditorViewModel())
}
