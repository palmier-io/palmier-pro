import SwiftUI

struct SkillDetailSheet: View {
    enum Mode: Identifiable {
        case draft
        case existing(id: String)

        var id: String {
            switch self {
            case .draft: "draft"
            case let .existing(id): id
            }
        }
    }

    @Bindable private var store = SkillStore.shared
    @Bindable private var catalog = SkillCatalog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var skillID: String?
    @State private var editing: Bool
    @State private var draft: String
    @State private var originalDraft: String
    @State private var skillPendingDeletion: Skill?
    @State private var isUpdating = false
    @State private var isSaving = false
    @State private var editingTitle = false
    @State private var draftTitle = ""
    @State private var copyToast: CopyToast?
    @State private var showingSaveError = false
    @State private var failedExit: ExitAction?
    @FocusState private var titleFocused: Bool

    init(mode: Mode) {
        let skillID: String? = switch mode {
        case .draft: nil
        case let .existing(id): id
        }
        let isDraft = skillID == nil
        let draft = isDraft ? SkillStore.newSkillTemplate : ""
        _skillID = State(initialValue: skillID)
        _editing = State(initialValue: isDraft)
        _draft = State(initialValue: draft)
        _originalDraft = State(initialValue: draft)
        _editingTitle = State(initialValue: isDraft)
        _draftTitle = State(initialValue: isDraft ? SkillFrontmatter.parse(draft).fields["name"] ?? "" : "")
    }

    private enum ExitAction {
        case close, preview
    }

    private struct CopyToast: Equatable {
        let agentLabel: String
        let url: URL

        var displayPath: String {
            url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        }
    }

    private var skill: Skill? {
        guard let skillID else { return nil }
        return store.skills.first { $0.id == skillID }
    }

    private var isDraft: Bool { skillID == nil }

    private var draftName: String {
        let name = SkillFrontmatter.parse(draft).fields["name"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { return L10n.string("New skill") }
        return name
    }

    var body: some View {
        Group {
            if isDraft {
                content(nil)
            } else if let skill {
                content(skill)
            } else {
                Text(L10n.string("Skill unavailable."))
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.Settings.skillDetailWidth)
                    .frame(minHeight: AppTheme.Settings.skillDetailMinHeight)
                    .overlay(alignment: .topTrailing) {
                        closeButton
                            .padding(.horizontal, AppTheme.Spacing.xlXxl)
                            .padding(.vertical, AppTheme.Spacing.mdLg)
                    }
            }
        }
        .interactiveDismissDisabled(isSaving || (!isDraft && (editing && draft != originalDraft || editingTitle)))
        .task {
            if isDraft { titleFocused = true }
        }
        .onExitCommand {
            if editingTitle {
                cancelTitleEditing()
            } else {
                close()
            }
        }
        .alert(L10n.string("Unable to save skill"), isPresented: $showingSaveError) {
            Button(L10n.string("Keep Editing"), role: .cancel) { failedExit = nil }
            if failedExit != nil {
                Button(L10n.string("Discard Changes"), role: .destructive) { discardChanges() }
            }
        } message: {
            Text(L10n.string("Add nonempty name and description fields to the skill frontmatter."))
        }
    }

    private func content(_ skill: Skill?) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            header(skill)

            if editing {
                editContent
            } else if let skill {
                ScrollView {
                    viewContent(skill)
                        .padding(AppTheme.Spacing.xlXxl)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .themedSurface(AppTheme.Background.raisedColor, cornerRadius: AppTheme.Radius.md)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md, style: .continuous))
                .padding(.horizontal, AppTheme.Spacing.xlXxl)
                .padding(.top, AppTheme.Spacing.mdLg)
                .padding(.bottom, AppTheme.Spacing.xlXxl)
            }
        }
        .frame(width: AppTheme.Settings.skillDetailWidth)
        .frame(minHeight: AppTheme.Settings.skillDetailMinHeight)
        .background(AppTheme.Background.prominentColor)
        .overlay(alignment: .top) {
            if let toast = copyToast {
                copyToastBanner(toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: AppTheme.Anim.transition), value: copyToast)
        .skillDeleteConfirmation(skill: $skillPendingDeletion) { skill in
            Task {
                if await store.delete(skill) {
                    dismiss()
                }
            }
        }
    }

    private func header(_ skill: Skill?) -> some View {
        let state = skill.flatMap { SkillCommunityState.resolve($0, store: store, catalog: catalog) }
        let dirty = editing && draft != originalDraft

        return VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.md) {
                titleView(editing ? draftName : skill?.name ?? draftName)
                Spacer(minLength: AppTheme.Spacing.md)
                closeButton
            }

            HStack(spacing: AppTheme.Spacing.smMd) {
                if skill != nil {
                    Text(verbatim: state.map { L10n.string(key: $0.label) } ?? L10n.string("Local"))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(state?.color ?? AppTheme.Text.tertiaryColor)
                }

                Spacer(minLength: AppTheme.Spacing.md)
                headerControls(skill: skill, state: state, dirty: dirty)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.vertical, AppTheme.Spacing.mdLg)
    }

    @ViewBuilder
    private func headerControls(
        skill: Skill?,
        state: SkillCommunityState?,
        dirty: Bool
    ) -> some View {
        if let skill {
            existingHeaderControls(skill: skill, state: state, dirty: dirty)
        } else {
            draftHeaderControls
        }
    }

    @ViewBuilder
    private func existingHeaderControls(
        skill: Skill,
        state: SkillCommunityState?,
        dirty: Bool
    ) -> some View {
        if state == .update, !editing {
            if isUpdating {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(L10n.string("Updating \(skill.name)"))
            } else {
                Button(L10n.string("Update")) { update(skill) }
                    .buttonStyle(.capsule(.secondary, fill: AnyShapeStyle(AppTheme.Background.raisedColor)))
            }
        }

        SkillExternalAgentMenu(skill: skill, store: store) { agent, url in
            copyToast = CopyToast(agentLabel: agent.label, url: url)
        }
        .disabled(editing)

        if dirty {
            Button(L10n.string("Save Changes")) {
                Task {
                    await commitTitle()
                    _ = await commitDraftIfDirty()
                }
            }
            .buttonStyle(.capsule(.prominent))
            .keyboardShortcut("s", modifiers: .command)
        }

        Button(editing ? L10n.string("Preview") : L10n.string("Edit")) {
            Task { await toggleEditing(skill) }
        }
        .buttonStyle(.capsule(.secondary, fill: AnyShapeStyle(AppTheme.Background.raisedColor)))

        actionsMenu(skill)
    }

    @ViewBuilder
    private var draftHeaderControls: some View {
        if isSaving {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(L10n.string("Save"))
        } else {
            Button(L10n.string("Save")) {
                Task { await saveDraft() }
            }
            .buttonStyle(.capsule(.prominent))
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.md, height: AppTheme.IconSize.md)
                .padding(AppTheme.Spacing.xs)
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityLabel(L10n.string("Close"))
        .help(L10n.string("Close"))
    }

    @ViewBuilder
    private func titleView(_ title: String) -> some View {
        if editingTitle {
            TextField(L10n.string("Skill name"), text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .accessibilityLabel(L10n.string("Skill name"))
                .focused($titleFocused)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
                .themedSurface(
                    AppTheme.Background.raisedColor,
                    cornerRadius: AppTheme.Radius.xs,
                    border: AppTheme.Accent.link.opacity(AppTheme.Opacity.medium)
                )
                .onSubmit { Task { await commitTitle() } }
                .onChange(of: titleFocused) { if !titleFocused { Task { await commitTitle() } } }
        } else {
            Button {
                beginTitleEditing(title)
            } label: {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("Rename Skill"))
            .help(L10n.string("Rename Skill"))
        }
    }

    private func actionsMenu(_ skill: Skill) -> some View {
        Menu {
            Button(L10n.string("Rename Skill"), systemImage: "pencil") {
                beginTitleEditing(skill.name)
            }
            Button(L10n.string("Show in Finder"), systemImage: "folder") {
                store.reveal(skill.path)
            }
            Divider()
            Button(L10n.string("Delete Skill"), systemImage: "trash", role: .destructive) {
                skillPendingDeletion = skill
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
        .accessibilityLabel(L10n.string("More skill actions"))
        .help(L10n.string("More skill actions"))
    }

    private func toggleEditing(_ skill: Skill) async {
        if editing {
            await finish(.preview)
            return
        }

        await beginEditing(skill)
    }

    private func beginEditing(_ skill: Skill) async {
        guard !editing else { return }
        await commitTitle()
        let raw = await store.rawContents(for: skill) ?? ""
        guard !Task.isCancelled, self.skill?.id == skill.id else { return }
        draft = raw
        originalDraft = raw
        editing = true
    }

    private func update(_ skill: Skill) {
        guard !editing, let entry = catalog.entry(id: skill.id) else { return }
        isUpdating = true
        Task {
            _ = await store.install(entry)
            isUpdating = false
        }
    }

    @discardableResult
    private func commitDraftIfDirty(onFailure exit: ExitAction? = nil) async -> Bool {
        guard draft != originalDraft else { return true }
        guard let skill, await store.save(skill, raw: draft) else {
            failedExit = exit
            showingSaveError = true
            return false
        }
        failedExit = nil
        originalDraft = draft
        return true
    }

    private func saveDraft() async {
        guard !isSaving else { return }
        isSaving = true
        await commitTitle()
        guard SkillFrontmatter.requiredFields(draft) != nil else {
            isSaving = false
            showingSaveError = true
            return
        }
        guard let id = await store.createSkill(raw: draft) else {
            isSaving = false
            showingSaveError = true
            return
        }
        skillID = id
        originalDraft = draft
        isSaving = false
    }

    private func commitTitle() async {
        guard editingTitle else { return }
        let name = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        editingTitle = false
        guard !name.isEmpty else { return }
        if isDraft {
            draft = SkillFrontmatter.replacingFields(draft, name: name)
            return
        }
        guard let skill else { return }
        if editing {
            draft = SkillFrontmatter.replacingFields(draft, name: name)
            return
        }
        guard name != skill.name else { return }
        await store.rename(skill, to: name)
    }

    private func beginTitleEditing(_ title: String) {
        draftTitle = title
        editingTitle = true
        titleFocused = true
    }

    private func cancelTitleEditing() {
        editingTitle = false
        draftTitle = skill?.name ?? draftName
    }

    private func close() {
        guard !isSaving else { return }
        if isDraft {
            dismiss()
        } else {
            Task { await finish(.close) }
        }
    }

    private func finish(_ action: ExitAction) async {
        guard skill != nil else {
            dismiss()
            return
        }
        await commitTitle()
        guard await commitDraftIfDirty(onFailure: action) else { return }
        switch action {
        case .close: dismiss()
        case .preview: editing = false
        }
    }

    private func discardChanges() {
        guard let action = failedExit else { return }
        failedExit = nil
        draft = originalDraft
        switch action {
        case .close: dismiss()
        case .preview: editing = false
        }
    }

    private func viewContent(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(L10n.string("Description"))
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(skill.description)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(AppTheme.Border.subtleColor)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text(L10n.string("Instructions"))
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                MarkdownText(
                    text: store.body(for: skill.id) ?? "",
                    proseFont: .system(size: AppTheme.FontSize.smMd),
                    blockSpacing: AppTheme.Spacing.sm
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editContent: some View {
        TextEditor(text: $draft)
            .font(.system(size: AppTheme.FontSize.sm, design: .monospaced))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .accessibilityLabel(L10n.string("Skill instructions"))
            .scrollContentBackground(.hidden)
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Background.raisedColor)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .padding(AppTheme.Spacing.xlXxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(isSaving)
    }

    private func copyToastBanner(_ toast: CopyToast) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Status.successColor)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(L10n.string("Added to \(toast.agentLabel)"))
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(toast.displayPath)
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: AppTheme.Spacing.md)

            Button(L10n.string("Open")) {
                store.reveal(toast.url)
                copyToast = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Accent.link)
        }
        .padding(.horizontal, AppTheme.Spacing.mdLg)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .frame(maxWidth: AppTheme.Settings.skillToastWidth)
        .themedSurface(
            AppTheme.Background.prominentColor,
            cornerRadius: AppTheme.Radius.md,
            border: AppTheme.Border.primaryColor,
            borderWidth: AppTheme.BorderWidth.hairline
        )
        .shadow(AppTheme.Shadow.lg)
        .padding(.top, AppTheme.Spacing.lgXl)
        .onTapGesture { copyToast = nil }
        .task(id: toast) {
            try? await Task.sleep(for: AppTheme.Settings.skillToastDuration)
            guard !Task.isCancelled else { return }
            copyToast = nil
        }
    }
}
