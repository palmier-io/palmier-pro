import SwiftUI

struct AudioPanelTab: View {
    private enum Tab: String, CaseIterable {
        case speech = "Speech", music = "Music"
    }

    @State private var tab: Tab = .speech

    var body: some View {
        VStack(spacing: 0) {
            TitleTabBar(titles: Tab.allCases.map(\.rawValue), selected: tab.rawValue, raisedBackground: true) { title in
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
