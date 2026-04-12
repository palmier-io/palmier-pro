import SwiftUI

struct HomeView: View {
    private let columns = [
        GridItem(.adaptive(minimum: 200, maximum: 240), spacing: 20)
    ]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            projectGrid
        }
        .frame(minWidth: 700, minHeight: 460)
        .background(Color(white: 0.08))
        .focusEffectDisabled()
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Palmier Pro")
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)

                Text("Video Editor")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            Spacer()

            Button(action: { AppState.shared.openProjectFromPanel() }) {
                Label("Open", systemImage: "folder")
            }
            .buttonStyle(.bordered)

            Button(action: { AppState.shared.createNewProject() }) {
                Label("New Project", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }

    private var projectGrid: some View {
        Group {
            if ProjectRegistry.shared.sortedEntries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(ProjectRegistry.shared.sortedEntries) { entry in
                            ProjectCard(
                                entry: entry,
                                onOpen: { AppState.shared.openProject(at: $0) },
                                onRemove: { ProjectRegistry.shared.remove($0) }
                            )
                        }
                    }
                    .padding(24)
                }
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

// MARK: - Home window controller

@MainActor
final class HomeWindowController: NSWindowController {
    static let shared = HomeWindowController()

    private init() {
        let hostingController = NSHostingController(rootView: HomeView())
        let window = NSWindow(contentViewController: hostingController)
        window.setContentSize(NSSize(width: 780, height: 520))
        window.minSize = NSSize(width: 600, height: 400)
        window.title = "Palmier Pro"
        window.setFrameAutosaveName("PalmierProHome")
        window.appearance = NSAppearance(named: .darkAqua)
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
