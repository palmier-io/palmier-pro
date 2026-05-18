import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case account
    case general
    case storage

    var id: String { rawValue }

    var label: String {
        switch self {
        case .account: return "Account"
        case .general: return "General"
        case .storage: return "Storage"
        }
    }

    var systemImage: String {
        switch self {
        case .account: return "person.circle"
        case .general: return "gearshape"
        case .storage: return "internaldrive"
        }
    }
}

struct SettingsView: View {
    @Bindable private var account = AccountService.shared
    @State private var selectedTab: SettingsTab = .account

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
        }
        .frame(minWidth: 760, idealWidth: 800, minHeight: 480, idealHeight: 520)
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
    @Bindable var account = AccountService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !account.isMisconfigured {
                identityStrip
            }
            tabList
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.35))
    }

    private var identityStrip: some View {
        HStack(spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryLabel)
                    .font(.system(size: AppTheme.FontSize.md, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(planLabel)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(account.isSignedIn ? Color.accentColor.opacity(0.30) : Color.white.opacity(0.10))
            Text(initial)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
        }
        .frame(width: 30, height: 30)
    }

    private var initial: String {
        if let email = account.account?.user.email, let first = email.first {
            return String(first).uppercased()
        }
        return "?"
    }

    private var primaryLabel: String {
        account.account?.user.email ?? "Anonymous"
    }

    private var planLabel: String {
        guard account.isSignedIn else { return "—" }
        return account.tier.planLabel
    }

    private var tabList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(visibleTabs) { tab in
                SidebarTabButton(
                    tab: tab,
                    isSelected: selectedTab == tab
                ) { selectedTab = tab }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
    }
}

private struct SidebarTabButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(tab.label)
                    .font(.system(size: AppTheme.FontSize.md))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(background)
            )
            .foregroundStyle(AppTheme.Text.primaryColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected { return Color.white.opacity(0.10) }
        if isHovered { return Color.white.opacity(0.05) }
        return .clear
    }
}

private struct SettingsDetail: View {
    let tab: SettingsTab

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(tab.label)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 16)

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
                    switch tab {
                    case .account:
                        AccountPane()
                    case .general:
                        NotificationsPane()
                        PrivacyPane()
                    case .storage:
                        StoragePane()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
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
                .padding(.top, 1)
        }
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: hosting)
        window.setContentSize(NSSize(width: 800, height: 520))
        window.minSize = NSSize(width: 760, height: 480)
        window.title = "Settings"
        window.setFrameAutosaveName("PalmierProSettings")
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.08, alpha: 0.4)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    SettingsView()
}
