import SwiftUI

struct SkillsPane: View {
    @State private var store = SkillStore.shared
    @State private var selection: String?
    @State private var query = ""
    @State private var editing = false
    @State private var draft = ""
    @State private var originalDraft = ""
    @State private var editSkillId: String?

    private var filtered: [Skill] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.skills }
        return store.skills.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    private var selected: Skill? {
        store.skills.first { $0.id == selection } ?? store.skills.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            Text("These skills are available to the in-app agent. For Claude/Codex/Cursor, use the copy button.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .fixedSize(horizontal: false, vertical: true)

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
            store.reload()
            if selection == nil { selection = store.skills.first?.id }
        }
        .onChange(of: selection) {
            editing = false
            editSkillId = nil
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
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.vertical, AppTheme.Spacing.smMd)

            Divider().overlay(AppTheme.Border.subtleColor)

            if filtered.isEmpty {
                Text(store.skills.isEmpty ? "No skills yet." : "No matches.")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: AppTheme.BorderWidth.hairline) {
                        ForEach(filtered) { skill in
                            SkillRow(skill: skill, isSelected: selected?.id == skill.id) {
                                selection = skill.id
                            }
                        }
                    }
                    .padding(AppTheme.Spacing.xs)
                }
                .frame(maxHeight: .infinity)
            }
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
            Text(skill.name)
                .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
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
            viewEditToggle(skill)
            SkillCopyMenu(skill: skill, store: store)
            SkillIconButton(systemName: "arrow.up.forward.app", help: "Reveal in Finder", tint: AppTheme.Accent.primary) {
                store.reveal(skill.path)
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xlXxl)
        .padding(.top, AppTheme.Spacing.md)
        .padding(.bottom, AppTheme.Spacing.md)
    }

    private func viewEditToggle(_ skill: Skill) -> some View {
        HStack(spacing: AppTheme.BorderWidth.hairline) {
            SkillSegmentButton(systemName: "eye", active: !editing) { editing = false }
            SkillSegmentButton(systemName: "chevron.left.forwardslash.chevron.right", active: editing) {
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
        VStack(alignment: .leading, spacing: AppTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text("DESCRIPTION")
                    .font(.system(size: AppTheme.FontSize.xs, weight: .semibold))
                    .tracking(AppTheme.Tracking.tight)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(skill.description)
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            MarkdownText(text: store.body(for: skill.id) ?? "")
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
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(tint)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                .padding(AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .fill(hovering ? Color.white.opacity(AppTheme.Opacity.faint) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct SkillSegmentButton: View {
    let systemName: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(active ? AppTheme.Text.primaryColor : AppTheme.Text.mutedColor)
                .padding(.horizontal, AppTheme.Spacing.sm)
                .padding(.vertical, AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .fill(fill)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        if active { return Color.white.opacity(AppTheme.Opacity.faint) }
        if hovering { return Color.white.opacity(AppTheme.Opacity.subtle) }
        return .clear
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
    @State private var hovering = false
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Accent.primary)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                .padding(AppTheme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: AppTheme.Radius.xs)
                        .fill(hovering ? Color.white.opacity(AppTheme.Opacity.faint) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AppTheme.Spacing.md)
                .padding(.vertical, AppTheme.Spacing.sm)
                .background(hovering ? Color.white.opacity(AppTheme.Opacity.subtle) : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SkillRow: View {
    let skill: Skill
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Image(systemName: "doc.text")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(isSelected ? AppTheme.Accent.primary : AppTheme.Text.mutedColor)
            Text(skill.name)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.smMd)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(fill)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }

    private var fill: Color {
        if isSelected { return Color.white.opacity(AppTheme.Opacity.faint) }
        if hovering { return Color.white.opacity(AppTheme.Opacity.subtle) }
        return .clear
    }
}
