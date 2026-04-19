import SwiftUI

struct ThinkingDots: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(AppTheme.Text.tertiaryColor)
                    .frame(width: 5, height: 5)
                    .opacity(phase == i ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.25), value: phase)
            }
        }
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
    }
}
