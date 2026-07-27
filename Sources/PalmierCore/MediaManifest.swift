import Foundation

public struct MediaManifest: Codable, Sendable, Equatable {
    public var version: Int = 2
    public var entries: [MediaManifestEntry] = []
    public var folders: [MediaFolder] = []

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try c.decodeIfPresent([MediaManifestEntry].self, forKey: .entries) ?? []
        folders = try c.decodeIfPresent([MediaFolder].self, forKey: .folders) ?? []
    }

    public init() {}

    private enum CodingKeys: String, CodingKey { case version, entries, folders }
}

public struct MediaManifestEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var name: String
    public var type: ClipType
    public var source: MediaSource
    public var duration: Double
    public var generationInput: GenerationInput?
    public var sourceWidth: Int?
    public var sourceHeight: Int?
    public var sourceFPS: Double?
    public var hasAudio: Bool?
    public var folderId: String?
    public var cachedRemoteURL: String?
    public var cachedRemoteURLExpiresAt: Date?
    public var generationStatus: String?
    public var importInput: MediaImportInput?

    public init(
        id: String,
        name: String,
        type: ClipType,
        source: MediaSource,
        duration: Double,
        generationInput: GenerationInput? = nil,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        sourceFPS: Double? = nil,
        hasAudio: Bool? = nil,
        folderId: String? = nil,
        cachedRemoteURL: String? = nil,
        cachedRemoteURLExpiresAt: Date? = nil,
        generationStatus: String? = nil,
        importInput: MediaImportInput? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.source = source
        self.duration = duration
        self.generationInput = generationInput
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.sourceFPS = sourceFPS
        self.hasAudio = hasAudio
        self.folderId = folderId
        self.cachedRemoteURL = cachedRemoteURL
        self.cachedRemoteURLExpiresAt = cachedRemoteURLExpiresAt
        self.generationStatus = generationStatus
        self.importInput = importInput
    }
}

public struct MediaImportInput: Codable, Sendable, Equatable {
    public var sourceURL: String? = nil
    public var sourcePath: String? = nil
    public var createdAt: Date? = nil

    public init(
        sourceURL: String? = nil,
        sourcePath: String? = nil,
        createdAt: Date? = nil
    ) {
        self.sourceURL = sourceURL
        self.sourcePath = sourcePath
        self.createdAt = createdAt
    }
}

public struct GenerationInput: Codable, Sendable, Equatable {
    public var prompt: String
    public var model: String
    public var duration: Int
    public var aspectRatio: String
    public var resolution: String?
    public var upscaleSettings: UpscaleSettings? = nil
    public var upscaleSourceWidth: Int? = nil
    public var upscaleSourceHeight: Int? = nil
    public var upscaleSourceFPS: Double? = nil
    public var quality: String?
    public var imageURLs: [String]?
    /// Image-only
    public var numImages: Int?
    /// Audio-only
    public var voice: String?
    public var lyrics: String?
    public var styleInstructions: String?
    public var instrumental: Bool?
    public var targetLanguage: String?
    public var multilingual: Bool?
    public var audioInput: String?
    /// Video-only
    public var generateAudio: Bool?
    public var referenceImageURLs: [String]?
    public var referenceVideoURLs: [String]?
    public var referenceAudioURLs: [String]?

    /// Asset IDs for the references.
    public var imageURLAssetIds: [String]?
    public var referenceImageAssetIds: [String]?
    public var referenceVideoAssetIds: [String]?
    public var referenceAudioAssetIds: [String]?
    public var createdAt: Date?
    public var backendJobId: String?
    public var outputIndex: Int?
    public var resultURLs: [String]?

    public init(
        prompt: String,
        model: String,
        duration: Int,
        aspectRatio: String,
        resolution: String? = nil,
        upscaleSettings: UpscaleSettings? = nil,
        upscaleSourceWidth: Int? = nil,
        upscaleSourceHeight: Int? = nil,
        upscaleSourceFPS: Double? = nil,
        quality: String? = nil,
        imageURLs: [String]? = nil,
        numImages: Int? = nil,
        voice: String? = nil,
        lyrics: String? = nil,
        styleInstructions: String? = nil,
        instrumental: Bool? = nil,
        targetLanguage: String? = nil,
        multilingual: Bool? = nil,
        audioInput: String? = nil,
        generateAudio: Bool? = nil,
        referenceImageURLs: [String]? = nil,
        referenceVideoURLs: [String]? = nil,
        referenceAudioURLs: [String]? = nil,
        imageURLAssetIds: [String]? = nil,
        referenceImageAssetIds: [String]? = nil,
        referenceVideoAssetIds: [String]? = nil,
        referenceAudioAssetIds: [String]? = nil,
        createdAt: Date? = nil,
        backendJobId: String? = nil,
        outputIndex: Int? = nil,
        resultURLs: [String]? = nil
    ) {
        self.prompt = prompt
        self.model = model
        self.duration = duration
        self.aspectRatio = aspectRatio
        self.resolution = resolution
        self.upscaleSettings = upscaleSettings
        self.upscaleSourceWidth = upscaleSourceWidth
        self.upscaleSourceHeight = upscaleSourceHeight
        self.upscaleSourceFPS = upscaleSourceFPS
        self.quality = quality
        self.imageURLs = imageURLs
        self.numImages = numImages
        self.voice = voice
        self.lyrics = lyrics
        self.styleInstructions = styleInstructions
        self.instrumental = instrumental
        self.targetLanguage = targetLanguage
        self.multilingual = multilingual
        self.audioInput = audioInput
        self.generateAudio = generateAudio
        self.referenceImageURLs = referenceImageURLs
        self.referenceVideoURLs = referenceVideoURLs
        self.referenceAudioURLs = referenceAudioURLs
        self.imageURLAssetIds = imageURLAssetIds
        self.referenceImageAssetIds = referenceImageAssetIds
        self.referenceVideoAssetIds = referenceVideoAssetIds
        self.referenceAudioAssetIds = referenceAudioAssetIds
        self.createdAt = createdAt
        self.backendJobId = backendJobId
        self.outputIndex = outputIndex
        self.resultURLs = resultURLs
    }
}

public enum MediaSource: Codable, Sendable, Equatable {
    case external(absolutePath: String)
    case project(relativePath: String)
}
