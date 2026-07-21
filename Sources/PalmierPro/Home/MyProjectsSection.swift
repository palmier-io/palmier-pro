import SwiftUI

struct MyProjectsSection: View {
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

    @State private var searchQuery = ""
    @State private var isSearchExpanded = false
    @State private var isSelecting = false
    @State private var selectedProjectIDs: Set<UUID> = []
    @State private var projectsPendingDeletion: [ProjectEntry] = []
    @State private var deletionMessage: String?
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            toolbar
            projectGrid
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var toolbar: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            Text("My Projects")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Spacer()

            if isSearchExpanded {
                searchField
                    .frame(width: AppTheme.ComponentSize.projectSearchWidth)
                    .transition(.opacity.combined(with: .scale(scale: AppTheme.Opacity.prominent, anchor: .trailing)))
            } else {
                Button {
                    isSearchExpanded = true
                    Task { isSearchFocused = true }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search projects")
                .help("Search projects")
            }

            if isSelecting {
                Button("Delete \(selectedProjectIDs.count)", role: .destructive) {
                    prepareDeletion()
                }
                .buttonStyle(.capsule(fill: AnyShapeStyle(AppTheme.Status.errorColor)))
                .disabled(selectedProjectIDs.isEmpty)
                Button("Done") { endSelection() }
                    .buttonStyle(.capsule)
            } else if !ProjectRegistry.shared.entries.isEmpty {
                Button("Select") { isSelecting = true }
                    .buttonStyle(.capsule)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.bottom, AppTheme.Spacing.sm)
        .animation(.easeInOut(duration: AppTheme.Anim.transition), value: isSearchExpanded)
        .alert(deletionTitle, isPresented: Binding(
            get: { !projectsPendingDeletion.isEmpty },
            set: { if !$0 { projectsPendingDeletion = [] } }
        )) {
            Button("Cancel", role: .cancel) { projectsPendingDeletion = [] }
            Button("Delete", role: .destructive) { deletePendingProjects() }
        } message: {
            Text(deletionPrompt)
        }
        .alert("Projects Couldn’t Be Deleted", isPresented: Binding(
            get: { deletionMessage != nil },
            set: { if !$0 { deletionMessage = nil } }
        )) {
            Button("OK") { deletionMessage = nil }
        } message: {
            Text(deletionMessage ?? "")
        }
        .onChange(of: ProjectRegistry.shared.entries.map(\.id)) { _, ids in
            selectedProjectIDs.formIntersection(ids)
            if ids.isEmpty { endSelection() }
        }
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
            TextField("Search projects", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .focused($isSearchFocused)
                .onExitCommand { collapseSearch() }
            if !searchQuery.isEmpty {
                Button(action: collapseSearch) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Clear search")
            }
        }
        .padding(.leading, AppTheme.Spacing.smMd)
        .padding(.trailing, AppTheme.Spacing.xs)
        .padding(.vertical, AppTheme.Spacing.xs)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    Color.white.opacity(AppTheme.Opacity.faint),
                    lineWidth: AppTheme.BorderWidth.thin
                )
        )
        .onChange(of: isSearchFocused) { _, focused in
            if !focused, searchQuery.isEmpty { isSearchExpanded = false }
        }
    }

    private var projectGrid: some View {
        let entries = filteredEntries
        return ScrollView {
            LazyVGrid(columns: columns, alignment: .leading, spacing: AppTheme.Spacing.xl) {
                if ProjectRegistry.shared.entries.isEmpty {
                    NewProjectCard(action: { AppState.shared.createProjectInteractively() })
                } else if entries.isEmpty {
                    Text("No projects found")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                        .padding(.vertical, AppTheme.Spacing.xl)
                } else {
                    ForEach(entries) { entry in
                        ProjectCard(
                            entry: entry,
                            isSelecting: isSelecting,
                            isSelected: selectedProjectIDs.contains(entry.id),
                            onOpen: { AppState.shared.openProject(at: $0) },
                            onRemove: { ProjectRegistry.shared.remove($0) },
                            onSelect: { toggleSelection(entry.id) },
                            onDelete: { requestDeletion([entry]) }
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

    private var filteredEntries: [ProjectEntry] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return ProjectRegistry.shared.sortedEntries }
        return ProjectRegistry.shared.sortedEntries.filter { $0.name.localizedStandardContains(query) }
    }

    private var deletionTitle: String {
        projectsPendingDeletion.count == 1 ? "Delete Project?" : "Delete Selected Projects?"
    }

    private var deletionPrompt: String {
        projectsPendingDeletion.count == 1
            ? "The project will be moved to the Trash."
            : "The selected projects will be moved to the Trash."
    }

    private func toggleSelection(_ id: UUID) {
        if selectedProjectIDs.contains(id) {
            selectedProjectIDs.remove(id)
        } else {
            selectedProjectIDs.insert(id)
        }
    }

    private func collapseSearch() {
        searchQuery = ""
        isSearchFocused = false
        isSearchExpanded = false
    }

    private func endSelection() {
        isSelecting = false
        selectedProjectIDs.removeAll()
    }

    private func prepareDeletion() {
        let selected = ProjectRegistry.shared.entries.filter { selectedProjectIDs.contains($0.id) }
        requestDeletion(selected)
    }

    private func requestDeletion(_ entries: [ProjectEntry]) {
        let open = openProjects(in: entries)
        guard open.isEmpty else {
            deletionMessage = "Close \(open.map(\.name).formatted()) before deleting."
            return
        }
        projectsPendingDeletion = entries
    }

    private func deletePendingProjects() {
        let ids = Set(projectsPendingDeletion.map(\.id))
        projectsPendingDeletion = []
        Task {
            do {
                let result = try await AppState.shared.deleteProjects(withIDs: ids)
                selectedProjectIDs.subtract(result.deletedIDs)
                if result.failedNames.isEmpty {
                    endSelection()
                } else {
                    deletionMessage = "Couldn’t move \(result.failedNames.formatted()) to the Trash."
                }
            } catch {
                deletionMessage = error.localizedDescription
            }
        }
    }

    private func openProjects(in entries: [ProjectEntry]) -> [ProjectEntry] {
        let paths = Set(AppState.shared.openProjects.compactMap { $0.fileURL?.standardizedFileURL.path })
        return entries.filter { paths.contains($0.url.standardizedFileURL.path) }
    }
}

private struct NewProjectCard: View {
    let action: () -> Void

    @State private var isHovered = false

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
                colors: [.clear, .black.opacity(AppTheme.Opacity.high)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: AppTheme.ComponentSize.projectCardHeight / 2)
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
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.mdLg, style: .continuous)
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
