import SwiftUI

/// Left-dock panel that hosts the Media and Captions tabs.
struct MediaPanelView: View {
    @State private var panelTab: PanelTab = .media

    enum PanelTab: String, CaseIterable {
        case media = "Media", captions = "Captions"
        var icon: String {
            switch self {
            case .media: "rectangle.stack"
            case .captions: "captions.bubble"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            panelTabBar
            Group {
                switch panelTab {
                case .media: MediaTab()
                case .captions: CaptionTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(AppTheme.Border.subtleColor).frame(width: AppTheme.BorderWidth.hairline)
        }
    }

    private var panelTabBar: some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                let selected = panelTab == tab
                Button {
                    withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) { panelTab = tab }
                } label: {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: tab.icon)
                            .font(.system(size: AppTheme.FontSize.sm))
                        Text(tab.rawValue)
                            .font(.system(size: AppTheme.FontSize.xs, weight: selected ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium))
                    }
                    .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                    .padding(.horizontal, AppTheme.Spacing.smMd)
                    .frame(height: Layout.panelHeaderHeight)
                    .contentShape(Rectangle())
                    .overlay(alignment: .bottom) {
                        if selected {
                            Rectangle()
                                .fill(AppTheme.Text.primaryColor)
                                .frame(height: AppTheme.BorderWidth.medium)
                        }
                    }
                }
                .buttonStyle(.plain)
                .focusable(false)
            }
            Spacer(minLength: AppTheme.Spacing.xxs)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .panelHeaderBar()
    }
}
