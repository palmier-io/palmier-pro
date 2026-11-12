import SwiftUI

struct TimelinePaneView: View {
    @Environment(EditorViewModel.self) private var editor

    var body: some View {
        VStack(spacing: 0) {
            if editor.isTimelineTabBarExpanded {
                TimelineTabBar()
            }
            ToolbarView()
                .frame(height: Layout.toolbarHeight)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(AppTheme.Border.primaryColor)
                        .frame(height: AppTheme.BorderWidth.thin)
                }
                .zIndex(1)
            HStack(spacing: 0) {
                TimelineContainerView()
                AudioMeterView()
            }
        }
    }
}
