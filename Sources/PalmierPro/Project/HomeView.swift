import SwiftUI

struct HomeView: View {
    private let columns = [
        GridItem(
            .adaptive(
                minimum: AppTheme.ComponentSize.projectCardWidth,
                maximum: AppTheme.ComponentSize.projectCardWidth
            ),
            spacing: AppTheme.Spacing.md,
            alignment: .leading
        )
    ]

    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @Bindable private var changelog = ChangelogStore.shared

    var body: some View {
        HStack(spacing: 0) {
            HomeSidebar()
                .frame(width: AppTheme.Settings.sidebarWidth)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black.opacity(AppTheme.Opacity.medium))
        }
        .frame(
            minWidth: AppTheme.Window.homeMin.width,
            maxWidth: .infinity,
            minHeight: AppTheme.Window.homeMin.height,
            maxHeight: .infinity
        )
        .background(.ultraThinMaterial)
        .focusEffectDisabled()
        .task { await VisualModelLoader.shared.prepare() }
        .onAppear { changelog.checkForWhatsNew() }
        .overlay {
            if !hasSeenWelcome {
                WelcomeOverlay { withAnimation { hasSeenWelcome = true } }
            } else if let entry = changelog.pending {
                UpdateOverlay(entry: entry, changelogURL: changelog.changelogURL) {
                    withAnimation { changelog.dismiss() }
                }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            SampleProjectsStrip()
            Text("My Projects")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(.horizontal, AppTheme.Spacing.xlXxl)
                .padding(.bottom, AppTheme.Spacing.sm)
            projectGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            WelcomeTitle()

            Spacer()
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.top, AppTheme.Spacing.lg)
        .padding(.bottom, AppTheme.Spacing.xxl)
    }

    private var projectGrid: some View {
        let entries = ProjectRegistry.shared.sortedEntries
        return ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.xl) {
                if entries.isEmpty {
                    NewProjectCard(action: { AppState.shared.createProjectInteractively() })
                } else {
                    ForEach(entries) { entry in
                        ProjectCard(
                            entry: entry,
                            onOpen: { AppState.shared.openProject(at: $0) },
                            onRemove: { ProjectRegistry.shared.remove($0) }
                        )
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.bottom, AppTheme.Spacing.xlXxl)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NewProjectCard: View {
    let action: () -> Void

    @State private var isHovered = false

    private let cardRadius: CGFloat = AppTheme.Radius.mdLg

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            AppTheme.Background.placeholderColor
                .aspectRatio(5.0/4.0, contentMode: .fit)
                .overlay {
                    Image(systemName: "plus")
                        .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .clipped()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.7), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 60)
            .allowsHitTesting(false)

            Text("Untitled")
                .font(.system(size: AppTheme.FontSize.smMd, weight: .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.bottom, AppTheme.Spacing.smMd)
        }
        .contentShape(Rectangle())
        .onTapGesture { action() }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(isHovered ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        )
        .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 12 : 4, y: isHovered ? 4 : 2)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .padding(AppTheme.Spacing.xs)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
    }
}

private struct WelcomeTitle: View {
    @Bindable private var account = AccountService.shared

    var body: some View {
        Text(title)
            .font(.system(size: AppTheme.FontSize.title2, weight: .light))
            .tracking(AppTheme.Tracking.tight)
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
    @Bindable private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if account.isSignedIn {
                IdentityStrip()
            }

            VStack(alignment: .leading, spacing: 2) {
                if !account.isSignedIn && !account.isMisconfigured {
                    SidebarRowButton(
                        label: account.isSigningIn ? "Opening Google…" : "Sign in with Google",
                        systemImage: "person.crop.circle",
                        action: { Task { await account.signInWithGoogle() } }
                    )
                    .disabled(account.isSigningIn)
                }
                SidebarRowButton(
                    label: "New Project",
                    systemImage: "plus",
                    action: { AppState.shared.createProjectInteractively() }
                )
                SidebarRowButton(
                    label: "Open Project",
                    systemImage: "folder",
                    action: { AppState.shared.openProjectFromPanel() }
                )
            }
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.vertical, AppTheme.Spacing.md)

            Spacer(minLength: 0)

            UpdateSidebarCard()
                .padding(.horizontal, AppTheme.Spacing.smMd)
                .padding(.bottom, AppTheme.Spacing.sm)
                .animation(.easeInOut(duration: AppTheme.Anim.transition), value: updater.updateAvailable)

            SidebarRowButton(
                label: "Settings",
                systemImage: "gearshape",
                action: { SettingsWindowController.shared.show() }
            )
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .padding(.bottom, AppTheme.Spacing.md)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Home window controller

@MainActor
final class HomeWindowController: NSWindowController {
    static let shared = HomeWindowController()

    private init() {
        let hostingController = NSHostingController(rootView: HomeView().tint(AppTheme.Accent.primary))
        hostingController.sizingOptions = .minSize
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(AppTheme.Window.homeDefault)
        window.minSize = AppTheme.Window.homeMin
        window.title = "Palmier Pro"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = AppTheme.Background.base.withAlphaComponent(0.4)
        window.isOpaque = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.collectionBehavior = [.fullScreenNone]
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
