import SwiftUI

struct SkillsPane: View {
    @State private var store = SkillStore.shared
    @State private var catalog = SkillCatalog.shared
    @State private var selection: String?
    @State private var query = ""
    @State private var editing = false
    @State private var draft = ""
    @State private var originalDraft = ""
    @State private var editSkillId: String?
    @State private var confirmingDelete = false
    @State private var installing: Set<String> = []
    @State private var showMy = true
    @State private var showCommunity = true
    @State private var editingTitle = false
    @State private var draftTitle = ""
    @FocusState private var titleFocused: Bool

    enum CommunityState { case upToDate, update, modified }

    private func matches(_ name: String, _ description: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || name.lowercased().contains(q) || description.lowercased().contains(q)
    }

    private var filtered: [Skill] {
        store.skills.filter { matches($0.name, $0.description) }
    }

    /// No ledger entry → the user's own; in the ledger → installed from the catalog.
    private var mySkills: [Skill] { filtered.filter { store.installed[$0.id] == nil } }
    private var communitySkills: [Skill] { filtered.filter { store.installed[$0.id] != nil } }

    private var availableEntries: [SkillCatalogEntry] {
        let local = Set(store.skills.map(\.id))
        return catalog.entries
            .filter { !local.contains($0.id) }
            .filter { matches($0.name, $0.description) }
    }

    /// Community section: installed-from-catalog skills plus not-yet-installed catalog
    /// entries, merged and sorted by name. (The id sets are disjoint by construction.)
    enum CommunityItem: Identifiable {
        case installed(Skill)
        case available(SkillCatalogEntry)
        var id: String {
            switch self {
            case .installed(let s): s.id
            case .available(let e): e.id
            }
        }
        var sortName: String {
            switch self {
            case .installed(let s): s.name.lowercased()
            case .available(let e): e.name.lowercased()
            }
        }
    }

    private var communityItems: [CommunityItem] {
        (communitySkills.map { CommunityItem.installed($0) } + availableEntries.map { CommunityItem.available($0) })
            .sorted { $0.sortName < $1.sortName }
    }

    private var selected: Skill? {
        filtered.first { $0.id == selection } ?? filtered.first
    }

    private func communityState(_ skill: Skill) -> CommunityState {
        let ledger = store.installed[skill.id]
        if store.localSha(skill) != ledger { return .modified }
        if let entry = catalog.entry(id: skill.id), entry.sha != ledger { return .update }
        return .upToDate
    }

    /// The catalog entry to install when an update is available for a community skill.
    private func updateEntry(_ skill: Skill) -> SkillCatalogEntry? {
        guard store.installed[skill.id] != nil, communityState(skill) == .update else { return nil }
        return catalog.entry(id: skill.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("These skills are available to the in-app agent. For Claude/Codex/Cursor, use the copy button.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                if let url = URL(string: "https://github.com/palmier-io/palmier-skills") {
                    Link("Check out community skills ↗", destination: url)
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Accent.primary)
                }
            }

            HStack(spacing: 0) {
                leftColumn
                    .frame(width: 220)
                Divider().overlay(AppTheme.Border.subtleColor)
                rightColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(height: 600)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .fill(Color.white.opacity(AppTheme.Opacity.subtle))
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                    .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        }
        .onAppear {
            if selection == nil { selection = store.skills.first?.id }
            Task { await store.reloadInBackground() }
            Task { await catalog.refresh() }
        }
        .onChange(of: selection) {
            if editing, draft != originalDraft, let edited = store.skills.first(where: { $0.id == editSkillId }) {
                store.save(edited, raw: draft)
            }
            editing = false
            editSkillId = nil
            editingTitle = false
        }
        .confirmationDialog(
            "Delete this skill?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible,
            presenting: selected
        ) { skill in
            Button("Delete \u{201C}\(skill.name)\u{201D}", role: .destructive) {
                store.delete(skill)
                selection = store.skills.first?.id
                editing = false
                editSkillId = nil
            }
        } message: { skill in
            Text("This permanently removes \(displayPath(skill)).")
        }
    }

    private func displayPath(_ skill: Skill) -> String {
        skill.path.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: Left column (search + list)

    private var leftColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                TextField("Search skills", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                SkillIconButton(systemName: "plus", help: "New skill") { store.newSkill().map { selection = $0 } }
                SkillIconButton(systemName: "folder", help: "Open skills folder") { store.openFolder() }
                SkillIconButton(systemName: "arrow.clockwise", help: "Refresh catalog") {
                    Task { await catalog.refresh() }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)

            Divider().overlay(AppTheme.Border.subtleColor)

            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.BorderWidth.hairline) {
                    sectionHeader("My Skills", count: mySkills.count, expanded: $showMy)
                    if showMy { skillRows(mySkills) }
                    sectionHeader("Community", count: communityItems.count, expanded: $showCommunity)
                    if showCommunity { communityRows }
                    if let error = catalog.lastError, catalog.entries.isEmpty {
                        Text("Catalog: \(error)")
                            .font(.system(size: AppTheme.FontSize.xxs))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(AppTheme.Spacing.sm)
                    }
                }
                .padding(AppTheme.Spacing.xs)
            }
            .frame(maxHeight: .infinity)
        }
    }

    @ViewBuilder private func skillRows(_ items: [Skill]) -> some View {
        if items.isEmpty {
            emptyRow
        } else {
            ForEach(items) { skill in
                SkillRow(skill: skill, isSelected: selected?.id == skill.id, badge: badge(for: skill)) {
                    selection = skill.id
                }
            }
        }
    }

    @ViewBuilder private var communityRows: some View {
        if communityItems.isEmpty {
            emptyRow
        } else {
            ForEach(communityItems) { item in
                switch item {
                case .installed(let skill):
                    SkillRow(skill: skill, isSelected: selected?.id == skill.id, badge: badge(for: skill)) {
                        selection = skill.id
                    }
                case .available(let entry):
                    SkillAvailableRow(entry: entry, installing: installing.contains(entry.id)) {
                        installing.insert(entry.id)
                        Task {
                            await store.install(entry)
                            installing.remove(entry.id)
                            selection = entry.id
                        }
                    }
                }
            }
        }
    }

    private var emptyRow: some View {
        Text("None")
            .font(.system(size: AppTheme.FontSize.sm))
            .foregroundStyle(AppTheme.Text.mutedColor)
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xs)
    }

    private func sectionHeader(_ title: String, count: Int, expanded: Binding<Bool>) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Image(systemName: "chevron.right")
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .rotationEffect(.degrees(expanded.wrappedValue ? 90 : 0))
                Text(title.uppercased())
                    .font(.system(size: AppTheme.FontSize.xxs, weight: .semibold))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.mutedColor)
                Text("\(count)")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor.opacity(AppTheme.Opacity.prominent))
                Spacer()
            }
            .contentShape(Rectangle())
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.top, AppTheme.Spacing.smMd)
            .padding(.bottom, AppTheme.Spacing.xxs)
        }
        .buttonStyle(.plain)
    }

    private func badge(for skill: Skill) -> SkillRowBadge? {
        guard store.installed[skill.id] != nil else { return nil }
        switch communityState(skill) {
        case .update: return .update
        case .modified: return .modified
        case .upToDate: return nil
        }
    }

    private func commitTitle(_ skill: Skill) {
        guard editingTitle else { return }
        editingTitle = false
        store.rename(skill, to: draftTitle)
    }

    private func provenance(_ skill: Skill) -> String {
        guard let sha = store.installed[skill.id] else { return "Local skill" }
        switch communityState(skill) {
        case .modified: return "Community · modified locally"
        case .update: return "Community · update available"
        case .upToDate: return "Community · v\(sha)"
        }
    }

    // MARK: Right column

    @ViewBuilder private var rightColumn: some View {
        if let skill = selected {
            VStack(alignment: .leading, spacing: 0) {
                toolbar(skill)
                if editing {
                    editContent
                } else {
                    ScrollView {
                        viewContent(skill)
                            .padding(.horizontal, AppTheme.Spacing.xlXxl)
                            .padding(.top, AppTheme.Spacing.md)
                            .padding(.bottom, AppTheme.Spacing.xlXxl)
                    }
                }
            }
        } else {
            Text("Select a skill.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func toolbar(_ skill: Skill) -> some View {
        let dirty = editing && draft != originalDraft
        return HStack(spacing: AppTheme.Spacing.md) {
            if editingTitle {
                TextField("Name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .focused($titleFocused)
                    .padding(.horizontal, AppTheme.Spacing.xs)
                    .padding(.vertical, AppTheme.Spacing.xxs)
                    .background(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                            .fill(Color.white.opacity(AppTheme.Opacity.faint))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                            .strokeBorder(AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium),
                                          lineWidth: AppTheme.BorderWidth.thin)
                    )
                    .onSubmit { commitTitle(skill) }
                    .onExitCommand { editingTitle = false }
                    .onChange(of: titleFocused) { if !titleFocused { commitTitle(skill) } }
            } else {
                Text(skill.name)
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .help("Double-click to rename")
                    .onTapGesture(count: 2) {
                        guard !editing else { return }
                        draftTitle = skill.name
                        editingTitle = true
                        titleFocused = true
                    }
            }
            Spacer(minLength: AppTheme.Spacing.md)
            if editing, dirty {
                Text("Edited")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
            if editing {
                SkillSaveButton(dirty: dirty) {
                    store.save(skill, raw: draft)
                    originalDraft = draft
                }
            }
            if !editing, let entry = updateEntry(skill) {
                Button("Update") { Task { await store.install(entry) } }
                    .buttonStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                    .foregroundStyle(AppTheme.Accent.primary)
            }
            viewEditToggle(skill)
            SkillCopyMenu(skill: skill, store: store)
            SkillIconButton(systemName: "arrow.up.forward.app", help: "Reveal in Finder", tint: AppTheme.Accent.primary) {
                store.reveal(skill.path)
            }
            SkillIconButton(systemName: "trash", help: "Delete skill") { confirmingDelete = true }
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.top, AppTheme.Spacing.md)
        .padding(.bottom, AppTheme.Spacing.md)
    }

    private func viewEditToggle(_ skill: Skill) -> some View {
        HStack(spacing: AppTheme.BorderWidth.hairline) {
            SkillSegmentButton(systemName: "eye", active: !editing) { editing = false }
            SkillSegmentButton(systemName: "chevron.left.forwardslash.chevron.right", active: editing) {
                editingTitle = false
                if editSkillId != skill.id {
                    draft = (try? String(contentsOf: skill.path, encoding: .utf8)) ?? ""
                    originalDraft = draft
                    editSkillId = skill.id
                }
                editing = true
            }
        }
        .padding(AppTheme.BorderWidth.thin)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(Color.white.opacity(AppTheme.Opacity.subtle))
        )
    }

    // MARK: View / edit content

    private func viewContent(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text(provenance(skill))
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("DESCRIPTION")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(skill.description)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider().overlay(AppTheme.Border.subtleColor)
                .padding(.vertical, AppTheme.Spacing.xs)
            MarkdownText(
                text: store.body(for: skill.id) ?? "",
                proseFont: .system(size: AppTheme.FontSize.smMd),
                blockSpacing: AppTheme.Spacing.sm
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editContent: some View {
        TextEditor(text: $draft)
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .scrollContentBackground(.hidden)
            .padding(AppTheme.Spacing.md)
            .background(Color.white.opacity(AppTheme.Opacity.subtle))
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .padding(.horizontal, AppTheme.Spacing.xlXxl)
            .padding(.top, AppTheme.Spacing.md)
            .padding(.bottom, AppTheme.Spacing.xlXxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Hover-aware controls

private struct SkillIconButton: View {
    let systemName: String
    let help: String
    var tint: Color = AppTheme.Text.secondaryColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(tint)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                .padding(AppTheme.Spacing.xs)
                .hoverHighlight(cornerRadius: AppTheme.Radius.xs)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

private struct SkillSegmentButton: View {
    let systemName: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(active ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
                .hoverHighlight(cornerRadius: AppTheme.Radius.xs, isActive: active)
        }
        .buttonStyle(.plain)
    }
}

private struct SkillSaveButton: View {
    let dirty: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Save")
                .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                .foregroundStyle(dirty ? AppTheme.Accent.primary : AppTheme.Text.mutedColor)
                .opacity(hovering && dirty ? 0.75 : 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: .command)
        .disabled(!dirty)
        .onHover { hovering = $0 }
    }
}

private struct SkillCopyMenu: View {
    let skill: Skill
    let store: SkillStore
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Accent.primary)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                .padding(AppTheme.Spacing.xs)
                .hoverHighlight(cornerRadius: AppTheme.Radius.xs)
        }
        .buttonStyle(.plain)
        .help("Copy to agent")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("COPY TO")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .padding(.horizontal, AppTheme.Spacing.md)
                    .padding(.top, AppTheme.Spacing.smMd)
                    .padding(.bottom, AppTheme.Spacing.xs)
                ForEach(SkillExternalAgent.allCases, id: \.self) { agent in
                    SkillPopoverRow(label: agent.label) {
                        store.copy(skill, to: agent)
                        showing = false
                    }
                }
            }
            .padding(.bottom, AppTheme.Spacing.xs)
            .frame(minWidth: 168)
        }
    }
}

private struct SkillPopoverRow: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
        .buttonStyle(.plain)
    }
}

enum SkillRowBadge { case update, modified }

private struct SkillRow: View {
    let skill: Skill
    let isSelected: Bool
    var badge: SkillRowBadge? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "doc.text")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(isSelected ? AppTheme.Accent.primary : AppTheme.Text.mutedColor)
            Text(skill.name)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
            Spacer(minLength: AppTheme.Spacing.xs)
            badgeView
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverHighlight(cornerRadius: AppTheme.Radius.sm, isActive: isSelected)
        .onTapGesture(perform: action)
    }

    @ViewBuilder private var badgeView: some View {
        switch badge {
        case .update:
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Accent.primary)
        case .modified:
            Text("Modified")
                .font(.system(size: AppTheme.FontSize.xxs))
                .foregroundStyle(AppTheme.Text.mutedColor)
        case nil:
            EmptyView()
        }
    }
}

private struct SkillAvailableRow: View {
    let entry: SkillCatalogEntry
    let installing: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "doc.text")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.mutedColor)
            Text(entry.name)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .lineLimit(1)
            Spacer(minLength: AppTheme.Spacing.xs)
            if installing {
                ProgressView().controlSize(.small)
            } else {
                Button("Install", action: action)
                    .buttonStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .foregroundStyle(AppTheme.Accent.primary)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        .help(entry.description)
    }
}
