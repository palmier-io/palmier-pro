import SwiftUI

struct MediaPanelView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var panelTab: PanelTab = .media
    @State private var hoveredTab: PanelTab?

    enum PanelTab: String, CaseIterable {
        case media = "Media", captions = "Captions", audio = "Audio"
        var icon: String {
            switch self {
            case .media: "folder"
            case .captions: "captions.bubble"
            case .audio: "waveform"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            panelTabRail
                .layoutPriority(1)
                .zIndex(1)
            Group {
                switch panelTab {
                case .media: MediaTab()
                case .captions: CaptionTab()
                case .audio: AudioPanelTab()
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .zIndex(0)
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(AppTheme.Border.primaryColor).frame(width: AppTheme.BorderWidth.hairline)
        }
        .onChange(of: editor.mediaPanelShowMediaTabTick) { _, _ in
            withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) { panelTab = .media }
        }
        .overlay(alignment: .topLeading) {
            if let hoveredTab {
                hoverLabel(hoveredTab.rawValue)
                    .id(hoveredTab)
                    .offset(
                        x: AppTheme.MediaPanel.tabRailWidth + AppTheme.Spacing.xs,
                        y: hoverLabelOffsetY(for: hoveredTab)
                    )
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
    }

    private var panelTabRail: some View {
        VStack(spacing: AppTheme.Spacing.xs) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                panelTabButton(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppTheme.Spacing.sm)
        .padding(.top, AppTheme.Spacing.sm)
        .padding(.bottom, AppTheme.Spacing.sm)
        .frame(
            minWidth: AppTheme.MediaPanel.tabRailWidth,
            idealWidth: AppTheme.MediaPanel.tabRailWidth,
            maxWidth: AppTheme.MediaPanel.tabRailWidth
        )
        .frame(maxHeight: .infinity, alignment: .top)
        .fixedSize(horizontal: true, vertical: false)
        .background(AppTheme.Background.raisedColor)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(AppTheme.Border.primaryColor)
                .frame(width: AppTheme.BorderWidth.hairline)
        }
    }

    private func panelTabButton(_ tab: PanelTab) -> some View {
        let selected = panelTab == tab
        let hovered = hoveredTab == tab
        return Button {
            withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) { panelTab = tab }
        } label: {
            Image(systemName: tab.icon)
                .font(.system(size: AppTheme.FontSize.md, weight: selected ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium))
                .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.tertiaryColor)
                .frame(width: AppTheme.IconSize.lg, height: AppTheme.IconSize.lg)
                .contentShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
                .hoverHighlight(cornerRadius: AppTheme.Radius.sm, isActive: selected)
                .overlay(alignment: .leading) {
                    if selected {
                        Capsule()
                            .fill(AppTheme.Border.primaryColor)
                            .frame(width: AppTheme.BorderWidth.thick, height: AppTheme.IconSize.sm)
                    }
                }
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            withAnimation(.easeOut(duration: AppTheme.Anim.hover)) {
                hoveredTab = hovering ? tab : (hoveredTab == tab ? nil : hoveredTab)
            }
        }
        .accessibilityLabel(tab.rawValue)
        .zIndex(hovered ? 1 : 0)
    }

    private func hoverLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
            .foregroundStyle(AppTheme.Text.primaryColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, AppTheme.Spacing.smMd)
            .frame(height: AppTheme.IconSize.lg)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.Background.prominentColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(AppTheme.Border.primaryColor, lineWidth: AppTheme.BorderWidth.thin)
            )
            .shadow(AppTheme.Shadow.sm)
            .allowsHitTesting(false)
    }

    private func hoverLabelOffsetY(for tab: PanelTab) -> CGFloat {
        let index = CGFloat(PanelTab.allCases.firstIndex(of: tab) ?? 0)
        return AppTheme.Spacing.sm + index * (AppTheme.IconSize.lg + AppTheme.Spacing.xs)
    }
}
