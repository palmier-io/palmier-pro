import SwiftUI

struct SkillDetailSheet: View {
    let skillID: String

    @Bindable private var store = SkillStore.shared
    @Bindable private var catalog = SkillCatalog.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var draft = ""
    @State private var originalDraft = ""
    @State private var confirmingDelete = false
    @State private var isUpdating = false
    @State private var editingTitle = false
    @State private var draftTitle = ""
    @State private var copyToast: CopyToast?
    @State private var showingSaveError = false
    @State private var failedExit: ExitAction?
    @FocusState private var titleFocused: Bool

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
        store.skills.first { $0.id == skillID }
    }

    private var deleteTitle: String {
        guard let skill else { return "Delete skill?" }
        return "Delete \u{201C}\(skill.name)\u{201D}?"
    }

    var body: some View {
        Group {
            if let skill {
                content(skill)
            } else {
                Text("Skill unavailable.")
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
        .interactiveDismissDisabled((editing && draft != originalDraft) || editingTitle)
        .onExitCommand {
            if editingTitle {
                cancelTitleEditing()
            } else {
                close()
            }
        }
        .alert("Unable to save skill", isPresented: $showingSaveError) {
            Button("Keep Editing", role: .cancel) { failedExit = nil }
            if failedExit != nil {
                Button("Discard Changes", role: .destructive) { discardChanges() }
            }
        } message: {
            Text("Add nonempty name and description fields to the skill frontmatter.")
        }
    }

    private func content(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.zero) {
            header(skill)
            Divider().overlay(AppTheme.Border.subtleColor)

            if editing {
                editContent
            } else {
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
        .confirmationDialog(
            deleteTitle,
            isPresented: $confirmingDelete,
            titleVisibility: .visible,
            presenting: self.skill
        ) { skill in
            Button("Delete \u{201C}\(skill.name)\u{201D}", role: .destructive) {
                store.delete(skill)
                dismiss()
            }
            Button("Keep Skill", role: .cancel) {}
        } message: { skill in
            Text("This permanently removes \(displayPath(skill)).")
        }
    }

    private func header(_ skill: Skill) -> some View {
        let state = SkillCommunityState.resolve(skill, store: store, catalog: catalog)
        let dirty = editing && draft != originalDraft

        return VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(spacing: AppTheme.Spacing.md) {
                titleView(skill)
                Spacer(minLength: AppTheme.Spacing.md)
                closeButton
            }

            HStack(spacing: AppTheme.Spacing.smMd) {
                Text(state?.label ?? "Local")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(state?.color ?? AppTheme.Text.tertiaryColor)

                Spacer(minLength: AppTheme.Spacing.md)

                if state == .update, !editing {
                    if isUpdating {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Updating \(skill.name)")
                    } else {
                        Button("Update") { update(skill) }
                            .buttonStyle(.capsule(.secondary, fill: AnyShapeStyle(AppTheme.Background.raisedColor)))
                    }
                }

                SkillExternalAgentMenu(skill: skill, store: store) { agent, url in
                    copyToast = CopyToast(agentLabel: agent.label, url: url)
                }
                .disabled(editing)

                if dirty {
                    Button("Save Changes") {
                        commitDraftIfDirty()
                    }
                    .buttonStyle(.capsule(.prominent))
                    .keyboardShortcut("s", modifiers: .command)
                }

                Button(editing ? "Preview" : "Edit") {
                    toggleEditing(skill)
                }
                .buttonStyle(.capsule(.secondary, fill: AnyShapeStyle(AppTheme.Background.raisedColor)))

                actionsMenu(skill)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.vertical, AppTheme.Spacing.mdLg)
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
        .accessibilityLabel("Close")
        .help("Close")
    }

    @ViewBuilder
    private func titleView(_ skill: Skill) -> some View {
        if editingTitle {
            TextField("Skill name", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .accessibilityLabel("Skill name")
                .focused($titleFocused)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
                .themedSurface(
                    AppTheme.Background.raisedColor,
                    cornerRadius: AppTheme.Radius.xs,
                    border: AppTheme.Accent.link.opacity(AppTheme.Opacity.medium)
                )
                .onSubmit { commitTitle() }
                .onChange(of: titleFocused) { if !titleFocused { commitTitle() } }
        } else {
            Text(skill.name)
                .font(.system(size: AppTheme.FontSize.xl, weight: AppTheme.FontWeight.regular))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
        }
    }

    private func actionsMenu(_ skill: Skill) -> some View {
        Menu {
            Button("Rename Skill", systemImage: "pencil") {
                draftTitle = skill.name
                editingTitle = true
                titleFocused = true
            }
            .disabled(editing)
            Button("Show in Finder", systemImage: "folder") {
                store.reveal(skill.path)
            }
            Divider()
            Button("Delete Skill", systemImage: "trash", role: .destructive) {
                confirmingDelete = true
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
        .accessibilityLabel("More skill actions")
        .help("More skill actions")
    }

    private func toggleEditing(_ skill: Skill) {
        if editing {
            finish(.preview)
            return
        }

        commitTitle()
        draft = (try? String(contentsOf: skill.path, encoding: .utf8)) ?? ""
        originalDraft = draft
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
    private func commitDraftIfDirty(onFailure exit: ExitAction? = nil) -> Bool {
        guard draft != originalDraft else { return true }
        guard let skill, store.save(skill, raw: draft) else {
            failedExit = exit
            showingSaveError = true
            return false
        }
        failedExit = nil
        originalDraft = draft
        return true
    }

    private func commitTitle() {
        guard editingTitle, let skill else { return }
        editingTitle = false
        store.rename(skill, to: draftTitle)
    }

    private func cancelTitleEditing() {
        editingTitle = false
        draftTitle = skill?.name ?? ""
    }

    private func close() {
        finish(.close)
    }

    private func finish(_ action: ExitAction) {
        guard skill != nil else {
            dismiss()
            return
        }
        guard commitDraftIfDirty(onFailure: action) else { return }
        commitTitle()
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

    private func displayPath(_ skill: Skill) -> String {
        skill.path.deletingLastPathComponent().path
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func viewContent(_ skill: Skill) -> some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xl) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("Description")
                    .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(skill.description)
                    .font(.system(size: AppTheme.FontSize.smMd))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(AppTheme.Border.subtleColor)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                Text("Instructions")
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
            .accessibilityLabel("Skill instructions")
            .scrollContentBackground(.hidden)
            .padding(AppTheme.Spacing.md)
            .background(AppTheme.Background.raisedColor)
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
            .padding(AppTheme.Spacing.xlXxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func copyToastBanner(_ toast: CopyToast) -> some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: AppTheme.FontSize.smMd, weight: AppTheme.FontWeight.semibold))
                .foregroundStyle(AppTheme.Status.successColor)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text("Added to \(toast.agentLabel)")
                    .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
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
