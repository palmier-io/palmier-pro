import SwiftUI

struct TitleBarLeadingView: View {
    var body: some View {
        HStack(spacing: 8) {
            // Home button
            Button(action: { AppState.shared.showHome() }) {
                Image(systemName: "house")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .frame(width: 22, height: 22)
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
        // Export button
        Button(action: { editor.showExportDialog = true }) {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.trailing, 8)
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
