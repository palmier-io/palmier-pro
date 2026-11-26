import SwiftUI

struct TimelineTabBar: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        TimelineTabBarContent(
            editor: editor,
            tabs: editor.openTimelineIds.compactMap { id in
                editor.timeline(for: id).map { TimelineTabInfo(id: $0.id, name: $0.name) }
            },
            allTabs: editor.timelines.map { TimelineTabInfo(id: $0.id, name: $0.name) },
            activeId: editor.activeTimelineId,
            renameRequest: editor.timelineTabRenameRequest
        )
        .equatable()
    }
}

private struct TimelineTabInfo: Equatable, Identifiable {
    let id: String
    let name: String
}

private struct TimelineTabBarContent: View, Equatable {
    let editor: EditorViewModel
    let tabs: [TimelineTabInfo]
    let allTabs: [TimelineTabInfo]
    let activeId: String
    let renameRequest: String?
    @State private var renamingTabId: String?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.tabs == rhs.tabs && lhs.allTabs == rhs.allTabs
            && lhs.activeId == rhs.activeId && lhs.renameRequest == rhs.renameRequest
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            overflowMenu
            TabStrip(
                items: tabs,
                activeId: activeId,
                scrollRequest: renameRequest,
                leadingPadding: 0
            ) { tab in
                tabItem(tab)
            } trailing: {
                addButton
            }
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: renameRequest) { _, id in
                guard let id else { return }
                editor.timelineTabRenameRequest = nil
                renamingTabId = id
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.md)
        .frame(maxWidth: .infinity)
        .frame(height: Layout.panelHeaderHeight)
        .background(AppTheme.Background.surfaceColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(AppTheme.Border.primaryColor)
                .frame(height: AppTheme.BorderWidth.thin)
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button(L10n.string("Show All Tabs")) {
                withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                    editor.openAllTimelineTabs()
                }
            }
            .disabled(tabs.count >= allTabs.count)
            Button(L10n.string("Close All Tabs")) {
                withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                    editor.closeAllTimelineTabs()
                }
            }
            .disabled(tabs.count <= 1)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.mdLg, height: AppTheme.IconSize.mdLg)
                .hoverHighlight()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.string("More"))
    }

    private func tabItem(_ tab: TimelineTabInfo) -> some View {
        let isActive = tab.id == activeId
        let canClose = tabs.count > 1 && renamingTabId != tab.id
        return HStack(spacing: AppTheme.Spacing.xs) {
            if renamingTabId == tab.id {
                renameField(tab)
            } else {
                Text(tab.name)
                    .font(.system(size: AppTheme.FontSize.xs, weight: isActive ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium))
                    .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                    .lineLimit(1)
            }
        }
        .documentTabChrome(
            isActive: isActive,
            isCloseable: canClose,
            onClose: canClose
                ? {
                    withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                        editor.closeTimelineTab(tab.id)
                    }
                }
                : nil
        )
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .gesture(TapGesture(count: 2).onEnded { renamingTabId = tab.id })
        .simultaneousGesture(TapGesture().onEnded { editor.activateTimeline(tab.id) })
        .contextMenu {
            Button(L10n.string("Rename")) { renamingTabId = tab.id }
            Button(L10n.string("Duplicate")) { editor.duplicateTimeline(tab.id) }
            Divider()
            Button(L10n.string("Close Tab")) { editor.closeTimelineTab(tab.id) }
                .disabled(tabs.count <= 1)
            Button(L10n.string("Close Other Tabs")) { editor.closeOtherTimelineTabs(keeping: tab.id) }
                .disabled(tabs.count <= 1)
            Divider()
            Button(L10n.string("Delete Timeline"), role: .destructive) { editor.deleteTimeline(tab.id) }
                .disabled(allTabs.count <= 1)
        }
    }

    private func renameField(_ tab: TimelineTabInfo) -> some View {
        InlineRenameField(
            originalName: tab.name,
            font: .system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold),
            onCommit: { name in
                editor.renameTimeline(tab.id, to: name)
                renamingTabId = nil
            },
            onCancel: { renamingTabId = nil }
        )
        .foregroundStyle(AppTheme.Text.primaryColor)
        .frame(width: AppTheme.ComponentSize.timelineTabRenameWidth)
    }

    private var addButton: some View {
        Button {
            editor.createTimeline()
        } label: {
            tabBarIcon("plus")
        }
        .buttonStyle(.plain)
        .help(L10n.string("New timeline"))
    }

    private func tabBarIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
            .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.md)
            .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
    }

}
