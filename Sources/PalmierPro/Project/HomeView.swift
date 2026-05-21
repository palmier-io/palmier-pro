import SwiftUI

struct HomeView: View {
    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 170), spacing: 18)
    ]

    var body: some View {
        HStack(spacing: 0) {
            HomeSidebar()
                .frame(width: 220)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(0.35))
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(.ultraThinMaterial)
        .focusEffectDisabled()
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            projectGrid
        }
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            WelcomeTitle()

            UpdateBadgeView()

            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 28)
    }

    @ViewBuilder
    private var projectGrid: some View {
        let entries = ProjectRegistry.shared.sortedEntries
        Group {
            if entries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(entries) { entry in
                            ProjectCard(
                                entry: entry,
                                onOpen: { AppState.shared.openProject(at: $0) },
                                onRemove: { ProjectRegistry.shared.remove($0) }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(AppTheme.Text.mutedColor)

            Text("No Recent Projects")
                .font(.system(size: AppTheme.FontSize.lg, weight: .medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            Text("Create a new project or open an existing one.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
    }
}

private struct WelcomeTitle: View {
    @Bindable private var account = AccountService.shared

    var body: some View {
        Text(title)
            .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
            .foregroundStyle(AppTheme.Text.primaryColor)
    }

    private var title: String {
        if let first = account.account?.user.firstName {
            return "Welcome to Palmier Pro, \(first)"
        }
        return "Welcome to Palmier Pro"
    }
}

private struct HomeSidebar: View {
    @Bindable private var account = AccountService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if account.isSignedIn {
                IdentityStrip()
            }

            VStack(alignment: .leading, spacing: 2) {
                if !account.isSignedIn && !account.isMisconfigured {
                    SidebarRowButton(
                        label: "Sign in with Google",
                        systemImage: "person.crop.circle",
                        action: { Task { await account.signInWithGoogle() } }
                    )
                }
                SidebarRowButton(
                    label: "New Project",
                    systemImage: "plus",
                    action: { AppState.shared.createNewProject() }
                )
                SidebarRowButton(
                    label: "Open Project",
                    systemImage: "folder",
                    action: { AppState.shared.openProjectFromPanel() }
                )
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)

            Spacer(minLength: 0)

            SidebarRowButton(
                label: "Settings",
                systemImage: "gearshape",
                action: { SettingsWindowController.shared.show() }
            )
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Home window controller

@MainActor
final class HomeWindowController: NSWindowController {
    static let shared = HomeWindowController()

    private init() {
        let hostingController = NSHostingController(rootView: HomeView())
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 980, height: 640))
        window.minSize = NSSize(width: 760, height: 480)
        window.title = "Palmier Pro"
        window.setFrameAutosaveName("PalmierProHome-v2")
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
}
