import SwiftUI

struct ClipGeneratingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            GeneratingOverlay()
        }
        .clipShape(RoundedRectangle(cornerRadius: Trim.clipCornerRadius))
        .allowsHitTesting(false)
    }
}
