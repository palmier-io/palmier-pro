import SwiftUI

struct TitleBarLeadingView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.smMd) {
            Circle()
                .fill(editor.isDocumentEdited ? AppTheme.Text.mutedColor : .clear)
                .frame(width: AppTheme.Spacing.sm, height: AppTheme.Spacing.sm)
                .help(editor.isDocumentEdited ? "Unsaved changes" : "")

            Button(action: { editor.agentPanelVisible.toggle() }) {
                Image(systemName: "bubble.left")
                    .font(.system(size: AppTheme.FontSize.md))
                    .foregroundStyle(AppTheme.aiGradient)
                    .opacity(editor.agentPanelVisible ? 1 : AppTheme.Opacity.strong)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
            }
            .buttonStyle(.plain)
            .help("Toggle Agent Panel")

            // Home button
            Button(action: { AppState.shared.showHome() }) {
                Image(systemName: "house")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)

            // Editable project name
            ProjectNameField(
                url: Binding(
                    get: { AppState.shared.activeProject?.fileURL },
                    set: { _ in }
                ),
                width: 160
            )
        }
        .padding(.leading, AppTheme.Spacing.sm)
    }
}

struct TitleBarTrailingView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            Spacer(minLength: 0)

            UpdateBadgeView()

            ProjectActivityButton()

            Button(action: { editor.showHelp = true }) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help("Keyboard Shortcuts (Cmd+?)")

            LayoutPresetMenu()

            Button(action: { editor.showExportDialog = true }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                    .hoverHighlight()
                    .help("Export (⌘E)")
            }
            .buttonStyle(.plain)

            UserAvatarButton()
        }
    }
}

/// Inline-editable project name.
struct ProjectNameField: View {
    @Binding var url: URL?
    var width: CGFloat = 160
    @State private var isEditing = false
    @State private var editText = ""
    @State private var showError = false
    @FocusState private var isFocused: Bool

    private var projectName: String {
        url?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    var body: some View {
        ZStack(alignment: .leading) {
            if isEditing {
                TextField("Project name", text: $editText)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .onSubmit { commitRename() }
                    .onChange(of: isFocused) { _, focused in
                        if !focused { commitRename() }
                    }
                    .onExitCommand { isEditing = false }
            } else {
                Text(projectName)
                    .lineLimit(1)
                    .onTapGesture { startEditing() }
            }
        }
        .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
        .foregroundStyle(isEditing ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.vertical, AppTheme.Spacing.xs)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(showError ? Color.red.opacity(AppTheme.Opacity.muted) : isEditing ? Color.white.opacity(AppTheme.Opacity.faint) : .clear)
        )
        .overlay(alignment: .trailing) {
            if showError {
                Text("Name in use")
                    .font(.system(size: AppTheme.FontSize.xxs))
                    .foregroundStyle(.red.opacity(AppTheme.Opacity.prominent))
                    .padding(.trailing, 6)
                    .transition(.opacity)
            }
        }
    }

    private func startEditing() {
        editText = projectName
        isEditing = true
        isFocused = true
    }

    private func commitRename() {
        guard let currentURL = url else {
            isEditing = false
            return
        }
        if let newURL = AppState.shared.renameProject(at: currentURL, to: editText) {
            url = newURL
            isEditing = false
            showError = false
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { showError = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { showError = false }
            }
        }
    }
}

// MARK: - Layout preset menu

struct LayoutPresetMenu: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        Menu {
            ForEach(LayoutPreset.allCases, id: \.self) { preset in
                Button {
                    editor.layoutPreset = preset
                } label: {
                    HStack {
                        Image(systemName: preset.icon)
                        Text(preset.label)
                    }
                }
                .disabled(editor.layoutPreset == preset)
            }
        } label: {
            Image(systemName: editor.layoutPreset.icon)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight()
        .help("Layout")
    }
}
