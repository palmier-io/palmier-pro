import Foundation

struct MediaManifest: Codable, Sendable, Equatable {
    var version: Int = 1
    var entries: [MediaManifestEntry] = []
}

struct MediaManifestEntry: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var type: ClipType
    var source: MediaSource
    var duration: Double
}

enum MediaSource: Codable, Sendable, Equatable {
    case external(absolutePath: String)
    case project(relativePath: String)
}
