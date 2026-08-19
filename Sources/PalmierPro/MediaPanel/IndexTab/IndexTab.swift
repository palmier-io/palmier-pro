import SwiftUI

enum IndexBrowserSection: String, CaseIterable {
    case transcript = "Transcript"
    case markers = "Markers"
    var titleKey: String { self == .transcript ? L10n.key("Transcript") : L10n.key("Markers") }
}

enum TranscriptIndexSource: Equatable {
    case automatic
    case transcript
    case captions(String)
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
    @Binding var section: IndexBrowserSection
    @Binding var transcript: EditorViewModel.TimelineTranscriptDocument?
    @Binding var source: TranscriptIndexSource
    @State private var emptySearchQuery = ""
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let timeline = editor.timeline
        let displayedTranscript = displayedTranscript(captions: captionSources)

        Group {
            switch section {
            case .transcript:
                if let displayedTranscript {
                    TranscriptBrowser(
                        document: displayedTranscript,
                        captionSources: captionSources,
                        source: $source,
                        indexSection: $section
                    )
                } else {
                    transcriptEmptyState
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
        .task(id: editor.timelineRenderRevision) {
            let revision = editor.timelineRenderRevision
            if let cached = await editor.cachedTimelineTranscript(),
               !cached.rows.isEmpty,
               transcript == nil,
               editor.timelineRenderRevision == revision {
                transcript = cached
            }
        }
    }

    private var transcriptEmptyState: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            HStack {
                if editor.isMediaPanelSearchExpanded {
                    ExpandablePanelSearch(text: $emptySearchQuery, focus: $isSearchFocused)
                        .layoutPriority(1)
                } else {
                    IndexModeTabs(selection: $section)
                    Spacer(minLength: AppTheme.Spacing.zero)
                    if !captionSources.isEmpty {
                        TranscriptSourceMenu(
                            document: nil,
                            captionSources: captionSources,
                            source: $source
                        )
                    }
                    ExpandablePanelSearch(text: $emptySearchQuery, focus: $isSearchFocused)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)

            Rectangle()
                .fill(AppTheme.Border.primaryColor)
                .frame(height: AppTheme.BorderWidth.hairline)

            CaptionTab(onGeneratedTranscript: {
                transcript = $0
                source = .transcript
            })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var captionSources: [EditorViewModel.TimelineTranscriptDocument] {
        TranscriptBrowserNavigation.captionFallbacks(in: editor.timeline)
    }

    private func displayedTranscript(
        captions: [EditorViewModel.TimelineTranscriptDocument]
    ) -> EditorViewModel.TimelineTranscriptDocument? {
        switch source {
        case .automatic:
            transcript ?? captions.first
        case .transcript:
            transcript
        case .captions(let groupId):
            captions.first { $0.sourceCaptionGroupId == groupId }
        }
    }
}
