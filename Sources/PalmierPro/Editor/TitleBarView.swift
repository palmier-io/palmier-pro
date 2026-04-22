import SwiftUI

struct TitleBarLeadingView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(editor.isDocumentEdited ? AppTheme.Text.mutedColor : .clear)
                .frame(width: 6, height: 6)
                .help(editor.isDocumentEdited ? "Unsaved changes" : "")

            Button(action: { editor.agentPanelVisible.toggle() }) {
                Image(systemName: "apple.intelligence")
                    .font(.system(size: 13))
                    .foregroundStyle(AppTheme.aiGradient)
                    .opacity(editor.agentPanelVisible ? 1 : 0.55)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Toggle Agent Panel")

            // Home button
            Button(action: { AppState.shared.showHome() }) {
                Image(systemName: "house")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: 26, height: 26)
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
        .padding(.leading, 6)
    }
}

struct TitleBarTrailingView: View {
    @Environment(EditorViewModel.self) var editor

    var body: some View {
        HStack(spacing: AppTheme.Spacing.sm) {
            ProjectActivityButton()

            Button(action: { editor.showHelp = true }) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: 26, height: 26)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
            .help("Keyboard Shortcuts (Cmd+?)")

            LayoutPresetMenu()

            Button(action: { editor.showExportDialog = true }) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: 26, height: 26)
                    .hoverHighlight()
            }
            .buttonStyle(.plain)
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
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                .fill(showError ? Color.red.opacity(0.15) : isEditing ? Color.white.opacity(0.08) : .clear)
        )
        .overlay(alignment: .trailing) {
            if showError {
                Text("Already exists")
                    .font(.system(size: 9))
                    .foregroundStyle(.red.opacity(0.8))
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
                .font(.system(size: 11))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: 26, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .hoverHighlight()
    }
}
