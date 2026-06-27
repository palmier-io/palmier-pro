import SwiftUI

struct SkillsPane: View {
    @Bindable private var store = SkillStore.shared
    @Bindable private var catalog = SkillCatalog.shared
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
    @State private var titleSkillId: String?
    @State private var copyToast: CopyToast?
    @FocusState private var titleFocused: Bool

    private struct CopyToast: Equatable {
        let agentLabel: String
        let url: URL

        var displayPath: String {
            url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }

    private enum CommunityState {
        case upToDate, update, modified

        var badge: SkillRowBadge? {
            switch self {
            case .update: .update
            case .modified: .modified
            case .upToDate: nil
            }
        }

        func provenance(sha: String) -> String {
            switch self {
            case .modified: "Community · modified locally"
            case .update: "Community · update available"
            case .upToDate: "Community · v\(sha)"
            }
        }
    }

    private enum CommunityItem: Identifiable {
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
        return catalog.entries.filter { !local.contains($0.id) && matches($0.name, $0.description) }
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

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("These skills are available to the in-app agent once installed. For Claude/Codex/Cursor, add them to their respective directories.")
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
            .frame(minHeight: 480, maxHeight: .infinity)
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
            .overlay(alignment: .top) {
                if let toast = copyToast {
                    copyToastBanner(toast)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: copyToast)
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.bottom, AppTheme.Spacing.xlXxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            if selection == nil { selection = store.skills.first?.id }
            Task { await store.reloadInBackground() }
            Task { await catalog.refresh() }
        }
        .onChange(of: selection) {
            commitDraftIfDirty()
            commitTitle()
            editing = false
            editSkillId = nil
        }
        .confirmationDialog(
            "Delete this skill?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible,
            presenting: selected
        ) { skill in
            Button("Delete \u{201C}\(skill.name)\u{201D}", role: .destructive) {
                commitDraftIfDirty()
                commitTitle()
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

    private func copyToastBanner(_ toast: CopyToast) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                .foregroundStyle(AppTheme.Status.successColor)
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Added to \(toast.agentLabel)")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(toast.displayPath)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: AppTheme.Spacing.md)
            Button("Open") {
                store.reveal(toast.url)
                copyToast = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
            .foregroundStyle(AppTheme.Accent.primary)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .frame(maxWidth: 380)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .fill(AppTheme.Background.prominentColor)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                        .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.hairline)
                )
        )
        .shadow(AppTheme.Shadow.lg)
        .padding(.top, AppTheme.Spacing.lgXl)
        .onTapGesture { copyToast = nil }
        .task(id: toast) {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            copyToast = nil
        }
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
                    if showMy { skillListRows(mySkills) }
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

    @ViewBuilder private func skillListRows(_ items: [Skill]) -> some View {
        if items.isEmpty { emptyRow }
        else { ForEach(items) { selectSkillRow($0) } }
    }

    @ViewBuilder private var communityRows: some View {
        if communityItems.isEmpty { emptyRow }
        else {
            ForEach(communityItems) { item in
                switch item {
                case .installed(let skill):
                    selectSkillRow(skill)
                case .available(let entry):
                    SkillAvailableRow(entry: entry, installing: installing.contains(entry.id)) {
                        installing.insert(entry.id)
                        Task {
                            let ok = await store.install(entry)
                            installing.remove(entry.id)
                            if ok { selection = entry.id }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func selectSkillRow(_ skill: Skill) -> some View {
        let badge = store.installed[skill.id] != nil ? communityState(skill).badge : nil
        SkillRow(skill: skill, isSelected: selected?.id == skill.id, badge: badge) {
            selection = skill.id
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

    private func commitDraftIfDirty() {
        guard draft != originalDraft,
              let id = editSkillId,
              let skill = store.skills.first(where: { $0.id == id }) else { return }
        store.save(skill, raw: draft)
        originalDraft = draft
    }

    private func commitTitle() {
        guard editingTitle else { return }
        editingTitle = false
        if let skill = store.skills.first(where: { $0.id == titleSkillId }) {
            store.rename(skill, to: draftTitle)
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
        let state = communityState(skill)
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
                    .onSubmit { commitTitle() }
                    .onExitCommand { editingTitle = false }
                    .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
            } else {
                Text(skill.name)
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
                    .help("Double-click to rename")
                    .onTapGesture(count: 2) {
                        guard !editing else { return }
                        draftTitle = skill.name
                        titleSkillId = skill.id
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
                Button { store.save(skill, raw: draft); originalDraft = draft } label: {
                    Text("Save")
                        .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                        .foregroundStyle(dirty ? AppTheme.Accent.primary : AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!dirty)
            }
            if !editing, state == .update, let entry = catalog.entry(id: skill.id) {
                Button("Update") { Task { await store.install(entry) } }
                    .buttonStyle(.plain)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                    .foregroundStyle(AppTheme.Accent.primary)
            }
            SkillCopyMenu(skill: skill, store: store) { agent, url in
                copyToast = CopyToast(agentLabel: agent.label, url: url)
            }
            viewEditToggle(skill)
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
                commitTitle()
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
            if let sha = store.installed[skill.id] {
                Text(communityState(skill).provenance(sha: sha))
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            } else {
                Text("Local skill")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
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

private struct SkillCopyMenu: View {
    let skill: Skill
    let store: SkillStore
    let onCopied: (SkillExternalAgent, URL) -> Void
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: AppTheme.Spacing.xs) {
                Text("Add to Claude")
                    .font(.system(size: AppTheme.FontSize.sm, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
            }
            .foregroundStyle(AppTheme.Accent.primary)
            .padding(.horizontal, AppTheme.Spacing.mdLg)
            .padding(.vertical, AppTheme.Spacing.xs)
            .background(
                Capsule()
                    .fill(AppTheme.Accent.primary.opacity(AppTheme.Opacity.subtle))
                    .overlay(
                        Capsule()
                            .strokeBorder(AppTheme.Accent.primary.opacity(AppTheme.Opacity.medium),
                                          lineWidth: AppTheme.BorderWidth.thin)
                    )
            )
        }
        .buttonStyle(.plain)
        .help("Add this skill to an agent")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(SkillExternalAgent.allCases, id: \.self) { agent in
                    Button {
                        if let url = store.copy(skill, to: agent) {
                            onCopied(agent, url)
                        }
                        showing = false
                    } label: {
                        Text("Add to \(agent.label)")
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
            .padding(.vertical, AppTheme.Spacing.xs)
            .frame(minWidth: 168)
        }
    }
}

private enum SkillRowBadge { case update, modified }

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
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hoverHighlight(cornerRadius: AppTheme.Radius.sm, isActive: isSelected)
        .onTapGesture(perform: action)
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
