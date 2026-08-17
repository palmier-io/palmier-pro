import SwiftUI

enum MediaPanelSection: String, CaseIterable {
    case media = "Media"
    case index = "Index"
    case captions = "Captions"
    case audio = "Audio"

    var title: String {
        switch self {
        case .media: L10n.key("Media")
        case .index: L10n.key("Index")
        case .captions: L10n.key("Captions")
        case .audio: L10n.key("Audio")
        }
    }

    var icon: String {
        switch self {
        case .media: "folder"
        case .index: "list.bullet.rectangle"
        case .captions: "captions.bubble"
        case .audio: "waveform"
        }
    }
}

struct MediaPanelView: View {
    @Environment(EditorViewModel.self) private var editor
    @State private var section: MediaPanelSection = .media
    @State private var indexSection: IndexBrowserSection = .captions
    @State private var selectedCaptionGroupId: String?

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            TitleTabBar(
                items: MediaPanelSection.allCases.map {
                    TitleTabBar.Item(titleKey: $0.title, systemImage: $0.icon)
                },
                selected: section.title
            ) { key in
                guard let match = MediaPanelSection.allCases.first(where: { $0.title == key }) else { return }
                editor.collapseMediaPanelSearch()
                withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
                    section = match
                }
            }

            Group {
                switch section {
                case .media: MediaTab()
                case .index:
                    IndexTab(
                        selectedCaptionGroupId: $selectedCaptionGroupId,
                        section: $indexSection
                    )
                case .captions:
                    CaptionTab { groupId in
                        selectedCaptionGroupId = groupId
                        indexSection = .captions
                        selectSection(.index)
                    }
                case .audio: AudioPanelTab()
                }
            }
            .padding(
                .top,
                section == .media ? AppTheme.Spacing.md : AppTheme.Spacing.zero
            )
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .onChange(of: editor.mediaPanelShowMediaTabTick) { _, _ in
            selectSection(.media)
        }
        .onChange(of: editor.mediaPanelSearchFocusTick) { _, _ in
            if section != .media, section != .index {
                selectSection(.media)
            }
        }
    }

    private func selectSection(_ newSection: MediaPanelSection) {
        withAnimation(.easeInOut(duration: AppTheme.Anim.transition)) {
            section = newSection
        }
    }
}
