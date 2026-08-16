import SwiftUI

struct IndexTab: View {
    @Environment(EditorViewModel.self) private var editor
    @Binding var selectedCaptionGroupId: String?
    @State private var emptySearchQuery = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let timeline = editor.timeline
        let captionGroups = CaptionBrowserNavigation.groups(in: timeline)

        Group {
            if captionGroups.isEmpty {
                emptyState
            } else {
                CaptionBrowser(
                    groups: captionGroups,
                    fps: timeline.fps,
                    selectedGroupId: $selectedCaptionGroupId
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.Background.surfaceColor)
    }

    private var emptyState: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            HStack {
                if editor.isMediaPanelSearchExpanded {
                    ExpandablePanelSearch(
                        text: $emptySearchQuery,
                        focus: $isSearchFocused
                    )
                        .layoutPriority(1)
                } else {
                    Spacer(minLength: AppTheme.Spacing.zero)
                    ExpandablePanelSearch(
                        text: $emptySearchQuery,
                        focus: $isSearchFocused
                    )
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.sm)

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
