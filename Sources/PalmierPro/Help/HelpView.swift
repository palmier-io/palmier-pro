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
    @State private var selectedTab: HelpTab

    init(initialTab: HelpTab = .shortcuts) {
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(AppTheme.Opacity.medium))
        }
        .frame(minWidth: 820, idealWidth: 900, minHeight: 520, idealHeight: 560)
        .background(.ultraThinMaterial)
        .focusEffectDisabled()
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            ForEach(HelpTab.allCases) { tab in
                sidebarRow(for: tab)
            }
            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.md)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func sidebarRow(for tab: HelpTab) -> some View {
        let isActive = selectedTab == tab
        return Button(action: { selectedTab = tab }) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: .medium))
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
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(selectedTab.rawValue)
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
            }
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.top, AppTheme.Spacing.xxl)
            .padding(.bottom, AppTheme.Spacing.lgXl)

            switch selectedTab {
            case .shortcuts: ShortcutsPane()
            case .mcp: MCPInstructionsPane()
            }
        }
    }
}

@MainActor
final class HelpWindowController: NSWindowController {
    static let shared = HelpWindowController()

    private var hosting: NSHostingController<AnyView>?

    private init() {
        let initialView = HelpView().tint(AppTheme.Accent.primary)
        let hosting = NSHostingController(rootView: AnyView(initialView))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 900, height: 560))
        window.minSize = NSSize(width: 820, height: 520)
        window.title = "Help"
        window.setFrameAutosaveName("PalmierProHelp-v1")
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(0.4)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.center()
        self.hosting = hosting
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(tab: HelpTab = .shortcuts) {
        hosting?.rootView = AnyView(
            HelpView(initialTab: tab)
                .id(UUID())
                .tint(AppTheme.Accent.primary)
        )
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    HelpView()
}
