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
    var generationInput: GenerationInput?
    var sourceWidth: Int?
    var sourceHeight: Int?
    var sourceFPS: Double?
    var hasAudio: Bool?
}

struct GenerationInput: Codable, Sendable, Equatable {
    var prompt: String
    var model: String
    var duration: Int
    var aspectRatio: String
    var resolution: String?
    var quality: String?
    var imageURLs: [String]?
    /// Image-only
    var numImages: Int?
    /// Audio-only
    var voice: String?
    var lyrics: String?
    var styleInstructions: String?
    var instrumental: Bool?
    /// Video-only
    var generateAudio: Bool?
    /// Metadata
    var estimatedCost: Double?
    var createdAt: Date?
}

enum MediaSource: Codable, Sendable, Equatable {
    case external(absolutePath: String)
    case project(relativePath: String)
}
