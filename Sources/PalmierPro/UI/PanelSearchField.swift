import SwiftUI

private struct PanelSearchField: View {
    @Binding var text: String
    let focus: FocusState<Bool>.Binding
    let onClear: () -> Void
    let onExit: () -> Void

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            TextField(L10n.string("Search"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .focused(focus)
                .onExitCommand(perform: onExit)
            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.mutedColor)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(L10n.string("Clear search"))
            }
        }
        .padding(.leading, AppTheme.Spacing.smMd)
        .padding(.trailing, AppTheme.Spacing.xs)
        .padding(.vertical, AppTheme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(AppTheme.Interaction.fill(AppTheme.Opacity.subtle))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    AppTheme.Interaction.fill(AppTheme.Opacity.faint),
                    lineWidth: AppTheme.BorderWidth.thin
                )
        )
    }
}

struct ExpandablePanelSearch: View {
    @Environment(EditorViewModel.self) private var editor
    @Binding var text: String
    let focus: FocusState<Bool>.Binding

    var body: some View {
        Group {
            if editor.isMediaPanelSearchExpanded {
                PanelSearchField(
                    text: $text,
                    focus: focus,
                    onClear: collapse,
                    onExit: collapse
                )
                .transition(.opacity.combined(with: .scale(
                    scale: AppTheme.Opacity.prominent,
                    anchor: .trailing
                )))
            } else {
                Button(action: expand) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)
                        .hoverHighlight()
                }
                .buttonStyle(.plain)
                .focusable(false)
                .hoverTooltip(
                    L10n.string("Search (⌘K)"),
                    alignment: .bottomTrailing
                )
            }
        }
        .onAppear { consumeFocusRequest() }
        .onChange(of: editor.mediaPanelSearchFocusTick) { _, _ in
            consumeFocusRequest()
        }
        .onChange(of: editor.isMediaPanelSearchExpanded) { _, expanded in
            if !expanded {
                text = ""
                focus.wrappedValue = false
            }
        }
        .onChange(of: focus.wrappedValue) { _, focused in
            if !focused, text.isEmpty { editor.collapseMediaPanelSearch() }
        }
    }

    private func expand() {
        editor.isMediaPanelSearchExpanded = true
        Task { focus.wrappedValue = true }
    }

    private func collapse() {
        editor.collapseMediaPanelSearch()
    }

    private func consumeFocusRequest() {
        guard editor.mediaPanelSearchFocusPending else { return }
        editor.mediaPanelSearchFocusPending = false
        expand()
    }
}
