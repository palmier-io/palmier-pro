import SwiftUI

struct MediaTabBar: View {
    @Binding var selected: ClipType

    var body: some View {
        Picker("", selection: $selected) {
            Text("Video").tag(ClipType.video)
            Text("Image").tag(ClipType.image)
            Text("Audio").tag(ClipType.audio)
        }
        .pickerStyle(.segmented)
        .controlSize(.small)
    }
}
