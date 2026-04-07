import AppKit

@Observable
@MainActor
final class MediaAsset: Identifiable {
    let id: String
    let url: URL
    let type: ClipType
    let name: String
    var duration: Double
    var thumbnail: NSImage?

    init(id: String = UUID().uuidString, url: URL, type: ClipType, name: String, duration: Double = 0, thumbnail: NSImage? = nil) {
        self.id = id
        self.url = url
        self.type = type
        self.name = name
        self.duration = duration
        self.thumbnail = thumbnail
    }
}
