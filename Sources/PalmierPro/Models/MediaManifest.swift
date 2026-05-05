import Foundation

struct MediaManifest: Codable, Sendable, Equatable {
    var version: Int = 2
    var entries: [MediaManifestEntry] = []
    var folders: [MediaFolder] = []

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try c.decodeIfPresent([MediaManifestEntry].self, forKey: .entries) ?? []
        folders = try c.decodeIfPresent([MediaFolder].self, forKey: .folders) ?? []
    }

    init() {}

    private enum CodingKeys: String, CodingKey { case version, entries, folders }
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
    var folderId: String?
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
    var referenceImageURLs: [String]?
    var referenceVideoURLs: [String]?
    var referenceAudioURLs: [String]?

    /// Asset IDs for the references.
    var imageURLAssetIds: [String]?
    var referenceImageAssetIds: [String]?
    var referenceVideoAssetIds: [String]?
    var referenceAudioAssetIds: [String]?
    /// Metadata
    var estimatedCost: Double?
    var createdAt: Date?
}

enum MediaSource: Codable, Sendable, Equatable {
    case external(absolutePath: String)
    case project(relativePath: String)
}
