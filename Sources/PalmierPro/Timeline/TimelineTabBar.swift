import SwiftUI

struct TimelineTabBar: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var renamingTabId: String?

    private var openTimelines: [Timeline] {
        editor.openTimelineIds.compactMap { editor.timeline(for: $0) }
    }

    var body: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppTheme.Spacing.md) {
                        ForEach(openTimelines) { timeline in
                            tabItem(timeline).id(timeline.id)
                        }
                        addButton
                    }
                    .padding(.horizontal, AppTheme.Spacing.sm)
                }
                .mouseWheelScrollsHorizontally()
                .onChange(of: editor.activeTimelineId) { _, newId in
                    withAnimation(.easeOut(duration: AppTheme.Anim.transition)) {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .panelHeaderBar()
    }

    private func tabItem(_ timeline: Timeline) -> some View {
        let isActive = timeline.id == editor.activeTimelineId
        return HStack(spacing: AppTheme.Spacing.xs) {
            if renamingTabId == timeline.id {
                renameField(timeline)
            } else {
                Text(timeline.name)
                    .font(.system(size: AppTheme.FontSize.xs, weight: isActive ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium))
                    .foregroundStyle(isActive ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                    .lineLimit(1)
            }

            if editor.openTimelineIds.count > 1 {
                closeButton(timeline.id)
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
        .gesture(TapGesture(count: 2).onEnded { beginRename(timeline) })
        .simultaneousGesture(TapGesture().onEnded { editor.activateTimeline(timeline.id) })
        .contextMenu {
            Button("Rename") { beginRename(timeline) }
            Button("Duplicate") { editor.duplicateTimeline(timeline.id) }
            Divider()
            Button("Close Tab") { editor.closeTimelineTab(timeline.id) }
                .disabled(editor.openTimelineIds.count <= 1)
            Button("Close Other Tabs") { editor.closeOtherTimelineTabs(keeping: timeline.id) }
                .disabled(editor.openTimelineIds.count <= 1)
            Divider()
            Button("Delete Timeline", role: .destructive) { editor.deleteTimeline(timeline.id) }
                .disabled(editor.timelines.count <= 1)
        }
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isActive)
    }

    private func renameField(_ timeline: Timeline) -> some View {
        InlineRenameField(
            originalName: timeline.name,
            font: .system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold),
            onCommit: { name in
                editor.renameTimeline(timeline.id, to: name)
                renamingTabId = nil
            },
            onCancel: { renamingTabId = nil }
        )
        .foregroundStyle(AppTheme.Text.primaryColor)
        .frame(width: AppTheme.ComponentSize.timelineTabRenameWidth)
    }

    private func beginRename(_ timeline: Timeline) {
        renamingTabId = timeline.id
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

    private func closeButton(_ id: String) -> some View {
        Button {
            withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                editor.closeTimelineTab(id)
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: AppTheme.FontSize.micro, weight: AppTheme.FontWeight.bold))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.xs, height: AppTheme.IconSize.xs)
                .hoverHighlight(cornerRadius: AppTheme.Radius.xs)
        }
        .buttonStyle(.plain)
    }
}
