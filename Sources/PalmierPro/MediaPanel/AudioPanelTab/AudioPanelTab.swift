import SwiftUI

struct AudioPanelTab: View {
    private enum Tab: String, CaseIterable {
        case speech = "Speech", music = "Music"

        var systemImage: String {
            switch self {
            case .speech: "mic"
            case .music: "music.note"
            }
        }
    }

    @State private var tab: Tab = .speech

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            TitleTabBar(
                items: Tab.allCases.map {
                    TitleTabBar.Item(titleKey: $0.rawValue, systemImage: $0.systemImage)
                },
                selected: tab.rawValue
            ) { title in
                if let t = Tab(rawValue: title) { tab = t }
            }
            switch tab {
            case .speech: SpeechTab()
            case .music: MusicTab()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.surfaceColor)
    }
}
