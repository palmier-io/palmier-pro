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
        HStack(spacing: AppTheme.Spacing.xs) {
            allTimelinesMenu
            TabStrip(items: tabs, activeId: activeId, scrollRequest: renameRequest) { tab in
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
        .panelHeaderBar()
    }

    private var allTimelinesMenu: some View {
        Menu {
            ForEach(allTabs) { tab in
                Button {
                    editor.activateTimeline(tab.id)
                } label: {
                    if tab.id == activeId {
                        Label(tab.name, systemImage: "checkmark")
                    } else {
                        Text(tab.name)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.md)
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.leading, AppTheme.Spacing.xs)
        .help("All timelines")
    }

    private func tabItem(_ tab: TimelineTabInfo) -> some View {
        let isActive = tab.id == activeId
        return HStack(spacing: AppTheme.Spacing.xs) {
            if renamingTabId == tab.id {
                renameField(tab)
            } else {
                Text(tab.name)
                    .font(.system(size: AppTheme.FontSize.xs, weight: isActive ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium))
                    .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                    .lineLimit(1)
            }

            if tabs.count > 1 {
                TabCloseButton {
                    withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                        editor.closeTimelineTab(tab.id)
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.Spacing.xs)
        .padding(.vertical, AppTheme.Spacing.xxs)
        .padding(.bottom, AppTheme.Spacing.xxs)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isActive ? AppTheme.Accent.primary : Color.clear)
                .frame(height: AppTheme.BorderWidth.medium)
        }
        .fixedSize()
        .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        .gesture(TapGesture(count: 2).onEnded { renamingTabId = tab.id })
        .simultaneousGesture(TapGesture().onEnded { editor.activateTimeline(tab.id) })
        .contextMenu {
            Button("Rename") { renamingTabId = tab.id }
            Button("Duplicate") { editor.duplicateTimeline(tab.id) }
            Divider()
            Button("Close Tab") { editor.closeTimelineTab(tab.id) }
                .disabled(tabs.count <= 1)
            Button("Close Other Tabs") { editor.closeOtherTimelineTabs(keeping: tab.id) }
                .disabled(tabs.count <= 1)
            Divider()
            Button("Delete Timeline", role: .destructive) { editor.deleteTimeline(tab.id) }
                .disabled(allTabs.count <= 1)
        }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isActive)
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
            Image(systemName: "plus")
                .font(.system(size: AppTheme.FontSize.sm, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.md)
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm)
        }
        .buttonStyle(.plain)
        .help("New timeline")
    }

}
