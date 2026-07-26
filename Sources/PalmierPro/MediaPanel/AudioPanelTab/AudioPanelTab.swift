import SwiftUI

struct AudioPanelTab: View {
    private enum Tab: String, CaseIterable {
        case speech = "Speech", music = "Music"
    }

    @State private var tab: Tab = .speech

    var body: some View {
        VStack(spacing: AppTheme.Spacing.zero) {
            TitleTabBar(
                titles: Tab.allCases.map(\.rawValue),
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
