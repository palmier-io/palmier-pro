import SwiftUI

enum IndexBrowserSection: String, CaseIterable {
    case captions = "Captions"
    case markers = "Markers"
    var titleKey: String { self == .captions ? L10n.key("Captions") : L10n.key("Markers") }
}

struct IndexModeTabs: View {
    @Binding var selection: IndexBrowserSection

    var body: some View {
        HStack(spacing: AppTheme.Spacing.md) {
            ForEach(IndexBrowserSection.allCases, id: \.self) { section in
                let selected = selection == section
                Button { selection = section } label: {
                    Text(L10n.string(key: section.titleKey))
                        .font(.system(
                            size: AppTheme.FontSize.sm,
                            weight: selected
                                ? AppTheme.FontWeight.semibold
                                : AppTheme.FontWeight.regular
                        ))
                        .foregroundStyle(
                            selected
                                ? AppTheme.Text.primaryColor
                                : AppTheme.Text.tertiaryColor
                        )
                        .frame(height: AppTheme.IconSize.md)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(selected
                                    ? AppTheme.Text.primaryColor
                                    : Color.clear)
                                .frame(height: AppTheme.BorderWidth.thin)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct IndexTab: View {
    @Environment(EditorViewModel.self) private var editor
    @Binding var selectedCaptionGroupId: String?
    @Binding var section: IndexBrowserSection
    @State private var emptySearchQuery = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let timeline = editor.timeline
        let captionGroups = CaptionBrowserNavigation.groups(in: timeline)

        Group {
            switch section {
            case .captions:
                if captionGroups.isEmpty {
                    captionEmptyState
                } else {
                    CaptionBrowser(
                        groups: captionGroups,
                        fps: timeline.fps,
                        selectedGroupId: $selectedCaptionGroupId,
                        indexSection: $section
                    )
                }
            case .markers:
                MarkerBrowser(
                    timeline: timeline,
                    indexSection: $section
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.Background.surfaceColor)
        .onChange(of: section) { _, _ in
            editor.collapseMediaPanelSearch()
        }
    }

    private var captionEmptyState: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            HStack {
                if editor.isMediaPanelSearchExpanded {
                    ExpandablePanelSearch(text: $emptySearchQuery, focus: $isSearchFocused)
                        .layoutPriority(1)
                } else {
                    IndexModeTabs(selection: $section)
                    Spacer(minLength: AppTheme.Spacing.zero)
                    ExpandablePanelSearch(text: $emptySearchQuery, focus: $isSearchFocused)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)

            Rectangle()
                .fill(AppTheme.Border.primaryColor)
                .frame(height: AppTheme.BorderWidth.hairline)

            VStack(spacing: AppTheme.Spacing.sm) {
                Spacer()
                Image(systemName: "captions.bubble")
                    .font(.system(
                        size: AppTheme.FontSize.xl,
                        weight: AppTheme.FontWeight.regular
                    ))
                    .foregroundStyle(AppTheme.Text.mutedColor)
                Text(L10n.string("No captions"))
                    .font(.system(
                        size: AppTheme.FontSize.sm,
                        weight: AppTheme.FontWeight.medium
                    ))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
