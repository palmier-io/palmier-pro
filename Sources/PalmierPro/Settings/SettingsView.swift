import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case account
    case general
    case agent
    case storage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .account: return "Account"
        case .general: return "General"
        case .agent: return "Agent"
        case .storage: return "Storage"
        }
    }

    var systemImage: String {
        switch self {
        case .account: return "person.circle"
        case .general: return "gearshape"
        case .agent: return "paperplane"
        case .storage: return "internaldrive"
        }
    }
}

struct SettingsView: View {
    @Bindable private var account = AccountService.shared
    @State private var selectedTab: SettingsTab

    init(initialTab: SettingsTab = .account) {
        _selectedTab = State(initialValue: initialTab)
    }

    private var visibleTabs: [SettingsTab] {
        SettingsTab.allCases.filter { tab in
            !(tab == .account && account.isMisconfigured)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(selectedTab: $selectedTab, visibleTabs: visibleTabs)
                .frame(width: 220)

            SettingsDetail(tab: selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(AppTheme.Opacity.medium))
        }
        .frame(minWidth: 760, idealWidth: 980, minHeight: 480, idealHeight: 640)
        .background(.ultraThinMaterial)
        .focusEffectDisabled()
        .onAppear {
            if !visibleTabs.contains(selectedTab) {
                selectedTab = visibleTabs.first ?? .general
            }
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var selectedTab: SettingsTab
    let visibleTabs: [SettingsTab]
    @Bindable private var account = AccountService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !account.isMisconfigured {
                IdentityStrip()
            }
            tabList
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var tabList: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
            ForEach(visibleTabs) { tab in
                SidebarRowButton(
                    label: tab.label,
                    systemImage: tab.systemImage,
                    isSelected: selectedTab == tab,
                    action: { selectedTab = tab }
                )
            }
        }
        .padding(.horizontal, AppTheme.Spacing.smMd)
        .padding(.vertical, AppTheme.Spacing.md)
    }
}

private struct SettingsDetail: View {
    let tab: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tab.label)
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
            }
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.top, AppTheme.Spacing.xxl)
            .padding(.bottom, AppTheme.Spacing.lgXl)

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    switch tab {
                    case .account:
                        AccountPane()
                    case .general:
                        NotificationsPane()
                        PrivacyPane()
                    case .agent:
                        AgentPane()
                    case .storage:
                        StoragePane()
                    }
                }
                .padding(.horizontal, AppTheme.Spacing.xlXxl)
                .padding(.bottom, AppTheme.Spacing.xlXxl)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
    }
}

struct SettingsToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(subtitle)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AppTheme.Spacing.lg)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .padding(.top, AppTheme.Spacing.xxs)
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private var hosting: NSHostingController<AnyView>?

    private init() {
        let initialView = SettingsView().tint(AppTheme.Accent.primary)
        let hosting = NSHostingController(rootView: AnyView(initialView))
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 980, height: 640))
        window.minSize = NSSize(width: 760, height: 480)
        window.title = "Settings"
        window.setFrameAutosaveName("PalmierProSettings-v2")
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

    func show(tab: SettingsTab? = nil) {
        if let tab {
            hosting?.rootView = AnyView(
                SettingsView(initialTab: tab)
                    .id(UUID())
                    .tint(AppTheme.Accent.primary)
            )
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    SettingsView()
}
