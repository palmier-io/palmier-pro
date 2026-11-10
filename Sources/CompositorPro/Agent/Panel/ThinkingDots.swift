import Combine
import SwiftUI

/// Pulsing dots shown while the agent is reasoning.
///
/// Deliberately not a spinner: it means work is happening, and it only appears once a reasoning
/// block actually exists, so a text-only turn never claims to have thought about anything.
struct ThinkingDots: View {
    @State private var phase = 0
    private let timer = Timer.publish(
        every: AppTheme.ActivityIndicator.pulseInterval,
        on: .main,
        in: .common
    ).autoconnect()

    var body: some View {
        HStack(spacing: AppTheme.ActivityIndicator.dotSpacing) {
            ForEach(0 ..< 3, id: \.self) { index in
                Circle()
                    .fill(AppTheme.Text.tertiaryColor)
                    .frame(width: AppTheme.ActivityIndicator.dotSize, height: AppTheme.ActivityIndicator.dotSize)
                    .opacity(phase == index ? 1 : AppTheme.ActivityIndicator.dimmedOpacity)
                    .animation(
                        .easeInOut(duration: AppTheme.ActivityIndicator.pulseDuration),
                        value: phase
                    )
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}
