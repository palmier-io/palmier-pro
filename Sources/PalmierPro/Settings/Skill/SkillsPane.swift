import SwiftUI

struct SkillsPane: View {
    @Bindable private var store = SkillStore.shared
    @Bindable private var catalog = SkillCatalog.shared
    @State private var collection: SkillCollection = .installed
    @State private var query = ""
    @State private var presentedSkill: PresentedSkill?
    @State private var installing: Set<String> = []
    @State private var updating: Set<String> = []

    private enum SkillCollection: String {
        case installed = "Installed"
        case community = "Community"
    }

    private struct PresentedSkill: Identifiable {
        let id: String
    }

    private var installedSkills: [Skill] {
        store.skills
            .filter { matches($0.name, $0.description) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var communityEntries: [SkillCatalogEntry] {
        catalog.entries
            .filter { matches($0.name, $0.description) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            introduction
            controls
            ScrollView {
                skillList
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .frame(maxWidth: AppTheme.Settings.contentMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, AppTheme.Spacing.xxl)
        .padding(.bottom, AppTheme.Spacing.xxl)
        .onAppear {
            Task { await store.reloadInBackground() }
            Task { await catalog.refresh() }
        }
        .sheet(item: $presentedSkill) { item in
            SkillDetailSheet(skillID: item.id)
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Install skills to give the in-app agent specialized workflows.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)

            if let url = URL(string: "https://github.com/palmier-io/palmier-skills") {
                Link("Browse Community Skills ↗", destination: url)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Accent.link)
                    .pointingHandCursor()
            }
        }
    }

    private var controls: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            HStack(spacing: AppTheme.Spacing.xxs) {
                SkillCollectionButton(
                    title: SkillCollection.installed.rawValue,
                    count: store.skills.count,
                    isSelected: collection == .installed,
                    action: { collection = .installed }
                )
                SkillCollectionButton(
                    title: SkillCollection.community.rawValue,
                    count: catalog.entries.count,
                    isSelected: collection == .community,
                    action: { collection = .community }
                )
            }

            Spacer(minLength: AppTheme.Spacing.md)

            searchField
                .frame(width: AppTheme.Settings.skillsSearchWidth)

            Button(action: createSkill) {
                Image(systemName: "plus")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    .padding(AppTheme.Spacing.xs)
                    .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New skill")
            .help("New skill")

            Menu {
                Button("Open Skills Folder", systemImage: "folder") { store.openFolder() }
                Divider()
                Button("Refresh Community Skills", systemImage: "arrow.clockwise") {
                    Task { await catalog.refresh() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                    .padding(AppTheme.Spacing.xs)
                    .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Skill actions")
            .help("Skill actions")
        }
    }

    private var searchField: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
                .accessibilityHidden(true)

            TextField("Search skills", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .accessibilityLabel("Search skills")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(AppTheme.Background.raisedColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .strokeBorder(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        )
    }

    @ViewBuilder
    private var skillList: some View {
        switch collection {
        case .installed:
            installedList
        case .community:
            communityList
        }
    }

    private var installedList: some View {
        listContainer {
            if installedSkills.isEmpty {
                if query.isEmpty {
                    SkillEmptyState(
                        systemName: "book.closed",
                        title: "No Installed Skills",
                        message: "Create a skill or browse the Community collection.",
                        actionTitle: "New Skill",
                        action: createSkill
                    )
                } else {
                    noMatchesState
                }
            } else {
                ForEach(installedSkills) { skill in
                    let state = store.installed[skill.id] == nil
                        ? nil
                        : SkillCommunityState.resolve(skill, store: store, catalog: catalog)
                    InstalledSkillRow(
                        skill: skill,
                        status: state?.label ?? "Local",
                        statusColor: state?.color ?? AppTheme.Text.tertiaryColor,
                        updating: updating.contains(skill.id),
                        updateAction: state == .update ? { update(skill) } : nil,
                        openAction: { present(skill.id) }
                    )
                }
            }
        }
    }

    private var communityList: some View {
        listContainer {
            if catalog.isLoading, catalog.entries.isEmpty {
                HStack(spacing: AppTheme.Spacing.smMd) {
                    ProgressView().controlSize(.small)
                    Text("Loading community skills…")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
                .frame(maxWidth: .infinity)
                .padding(AppTheme.Spacing.xlXxl)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Loading community skills")
            } else if communityEntries.isEmpty {
                if query.isEmpty, let error = catalog.lastError {
                    SkillEmptyState(
                        systemName: "exclamationmark.triangle",
                        title: "Community Skills Unavailable",
                        message: error,
                        actionTitle: "Try Again",
                        action: { Task { await catalog.refresh() } }
                    )
                } else if query.isEmpty {
                    SkillEmptyState(
                        systemName: "books.vertical",
                        title: "No Community Skills",
                        message: "Refresh to check for available skills.",
                        actionTitle: "Refresh",
                        action: { Task { await catalog.refresh() } }
                    )
                } else {
                    noMatchesState
                }
            } else {
                ForEach(communityEntries) { entry in
                    communityRow(entry)
                }
            }
        }
    }

    private var noMatchesState: some View {
        SkillEmptyState(
            systemName: "magnifyingglass",
            title: "No Matching Skills",
            message: "Try another search.",
            actionTitle: "Clear Search",
            action: { query = "" }
        )
    }

    private func listContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: AppTheme.Spacing.sm) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func communityRow(_ entry: SkillCatalogEntry) -> some View {
        let skill = store.skills.first { $0.id == entry.id }
        let isCommunityInstall = store.installed[entry.id] != nil
        let state = isCommunityInstall ? skill.map {
            SkillCommunityState.resolve($0, store: store, catalog: catalog)
        } : nil
        let isWorking = installing.contains(entry.id) || updating.contains(entry.id)

        CommunitySkillRow(
            entry: entry,
            status: isCommunityInstall ? state?.label ?? "Available" : skill == nil ? "Available" : "Local",
            statusColor: state?.color ?? AppTheme.Text.tertiaryColor,
            actionTitle: skill == nil ? "Install" : isCommunityInstall && state == .update ? "Update" : "Open",
            working: isWorking,
            action: {
                if let skill {
                    if isCommunityInstall, state == .update {
                        update(skill)
                    } else {
                        present(skill.id)
                    }
                } else {
                    install(entry)
                }
            }
        )
    }

    private func matches(_ name: String, _ description: String) -> Bool {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(search)
            || description.localizedCaseInsensitiveContains(search)
    }

    private func createSkill() {
        guard let id = store.newSkill() else { return }
        collection = .installed
        query = ""
        present(id)
    }

    private func install(_ entry: SkillCatalogEntry) {
        installing.insert(entry.id)
        Task {
            let installed = await store.install(entry)
            installing.remove(entry.id)
            if installed {
                collection = .installed
                query = ""
                present(entry.id)
            }
        }
    }

    private func update(_ skill: Skill) {
        guard let entry = catalog.entry(id: skill.id) else { return }
        updating.insert(skill.id)
        Task {
            _ = await store.install(entry)
            updating.remove(skill.id)
        }
    }

    private func present(_ id: String) {
        presentedSkill = PresentedSkill(id: id)
    }
}
