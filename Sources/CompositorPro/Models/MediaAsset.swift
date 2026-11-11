import AppKit
import AVFoundation

@Observable
@MainActor
final class MediaAsset: Identifiable {
    private nonisolated static let metadataLoadGate = AsyncSemaphore(value: 4)
    private nonisolated static let thumbnailLoadGate = AsyncSemaphore(value: 4)
    let id: String
    var url: URL {
        didSet {
            guard url != oldValue else { return }
            thumbnail = nil
            thumbnailMaxPixelSize = 0
            inputIdentity = nil
            inputIdentityVerified = false
            inputIdentityRevision = UUID()
        }
    }
    let type: ClipType
    var name: String
    var duration: Double
    var thumbnail: NSImage?
    var sourceWidth: Int?
    var sourceHeight: Int?
    var sourceFPS: Double?
    var hasAudio: Bool = false
    var generationInput: GenerationInput?
    var importInput: MediaImportInput?
    var inputIdentity: MediaInputIdentity? {
        didSet { if inputIdentity != oldValue { inputIdentityVerified = false } }
    }
    private(set) var inputIdentityVerified = false
    private var inputIdentityRevision = UUID()
    var generationStatus: GenerationStatus = .none
    var folderId: String?
    var pendingDownloadURL: URL?
    var cachedRemoteURL: String?
    var cachedRemoteURLExpiresAt: Date?
    private var thumbnailMaxPixelSize = 0

    /// Returns the cached URL if it's set AND not expired; else nil.
    var freshRemoteURL: String? {
        guard let url = cachedRemoteURL,
              let expiresAt = cachedRemoteURLExpiresAt,
              expiresAt > Date()
        else { return nil }
        return url
    }

    enum GenerationStatus: Equatable {
        case none
        case preparing
        case generating
        case downloading
        case rendering
        case failed(String)

        var serialized: String {
            switch self {
            case .none: "none"
            case .preparing: "preparing"
            case .generating: "generating"
            case .downloading: "downloading"
            case .rendering: "rendering"
            case .failed(let message): "failed: \(message)"
            }
        }

        // .none/.preparing are transient and must not restore as in-progress.
        var manifestValue: String? {
            switch self {
            case .none, .preparing: nil
            default: serialized
            }
        }

        init(serialized value: String?) {
            switch value {
            case "preparing": self = .preparing
            case "generating": self = .generating
            case "downloading": self = .downloading
            case "rendering": self = .rendering
            case let value? where value.hasPrefix("failed: "):
                self = .failed(String(value.dropFirst("failed: ".count)))
            default: self = .none
            }
        }
    }

    var isGenerated: Bool { generationInput != nil }

    var canEnhanceDraft: Bool {
        guard generationStatus == .none, let input = generationInput else { return false }
        return input.draft == true
            && input.backendJobId != nil
            && (input.resultURLs?.count ?? 0) >= 2
    }

    var draftEnhancementCost: Int? {
        guard let input = generationInput, input.draft == true,
              case .video(let model) = ModelRegistry.byId[input.model],
              let rate = model.draftEnhanceCreditsPerSecond,
              input.duration > 0 else { return nil }
        return Int((rate * Double(input.duration)).rounded(.up))
    }

    var resolvedDuration: Double {
        if duration.isFinite, duration > 0 { return duration }
        if let generated = generationInput?.duration, generated > 0 { return Double(generated) }
        return 0
    }
    var canResumeGeneration: Bool {
        guard let generationInput else { return false }
        return generationInput.backendJobId?.isEmpty == false
    }
    var isGenerating: Bool {
        generationStatus == .preparing || generationStatus == .generating || generationStatus == .downloading || generationStatus == .rendering
    }
    var isRecoveringGeneration: Bool {
        guard canResumeGeneration else { return false }
        if isGenerating { return true }
        if case .failed = generationStatus { return generationInput?.resultURLs?.isEmpty == false }
        return false
    }

    var wasGenerationRefunded: Bool {
        guard case .failed = generationStatus else { return false }
        return (generationInput?.refundedCredits ?? 0) > 0
    }
    var generatingLabel: String {
        switch generationStatus {
        case .preparing: L10n.key("Preparing…")
        case .downloading: L10n.key("Downloading…")
        case .rendering: L10n.key("Rendering…")
        default: L10n.key("Generating…")
        }
    }

    init(id: String = UUID().uuidString, url: URL, type: ClipType, name: String, duration: Double = 0, thumbnail: NSImage? = nil, generationInput: GenerationInput? = nil) {
        self.id = id
        self.url = url
        self.type = type
        self.name = name
        self.duration = duration
        self.thumbnail = thumbnail
        self.generationInput = generationInput
        self.hasAudio = (type == .video)
        if thumbnail != nil { thumbnailMaxPixelSize = .max }
    }

    /// Reconstruct from a manifest entry + resolved URL.
    convenience init(entry: MediaManifestEntry, resolvedURL: URL) {
        self.init(id: entry.id, url: resolvedURL, type: entry.type, name: entry.name, duration: entry.duration, generationInput: entry.generationInput)
        self.sourceWidth = entry.sourceWidth
        self.sourceHeight = entry.sourceHeight
        self.sourceFPS = entry.sourceFPS
        self.hasAudio = entry.hasAudio ?? false
        self.folderId = entry.folderId
        self.cachedRemoteURL = entry.cachedRemoteURL
        self.cachedRemoteURLExpiresAt = entry.cachedRemoteURLExpiresAt
        self.importInput = entry.importInput
        if self.importInput?.origin == nil, let assetId = entry.providerAssetId {
            var input = self.importInput ?? MediaImportInput()
            input.origin = MediaImportOrigin(
                provider: "stock",
                assetId: assetId,
                landingPageURL: entry.providerLandingURL,
                creator: entry.providerCreator,
                license: entry.providerLicense,
                attribution: entry.providerAttribution
            )
            input.createdAt = entry.providerRetrievalDate
            self.importInput = input
        }
        self.inputIdentity = entry.inputIdentity.flatMap { $0.isValid ? $0 : nil }
        let restoredStatus = GenerationStatus(serialized: entry.generationStatus)
        self.generationStatus = restoredStatus == .preparing && !canResumeGeneration ? .none : restoredStatus
    }

    /// Produce a serializable manifest entry from this asset.
    func toManifestEntry(projectURL: URL?) -> MediaManifestEntry {
        let source: MediaSource
        if let projectURL, url.path.hasPrefix(projectURL.path + "/") {
            let relative = String(url.path.dropFirst(projectURL.path.count + 1))
            source = .project(relativePath: relative)
        } else {
            source = .external(absolutePath: url.path)
        }
        let fresh: String? = freshRemoteURL
        return MediaManifestEntry(
            id: id, name: name, type: type, source: source, duration: duration,
            generationInput: generationInput,
            sourceWidth: sourceWidth, sourceHeight: sourceHeight, sourceFPS: sourceFPS,
            hasAudio: hasAudio, folderId: folderId,
            cachedRemoteURL: fresh,
            cachedRemoteURLExpiresAt: fresh == nil ? nil : cachedRemoteURLExpiresAt,
            generationStatus: generationStatus.manifestValue,
            importInput: importInput,
            inputIdentity: inputIdentity,

            // Stock provenance travels with the asset so credits survive reuse and repackaging.
            providerAssetId: importInput?.origin?.assetId,
            providerLandingURL: importInput?.origin?.landingPageURL,
            providerCreator: importInput?.origin?.creator,
            providerLicense: importInput?.origin?.license,
            providerAttribution: importInput?.origin?.attribution,
            providerRetrievalDate: importInput?.createdAt,
            providerCredits: nil,
        )
    }

    var inputIdentityReceipt: [String: Any] {
        MediaInputIdentity.receipt(identity: inputIdentity, verified: inputIdentityVerified, origin: importInput?.origin)
    }

    @ObservationIgnored private var identityPreparationAttempt: UUID?

    func prepareInputIdentity(
        validate: @MainActor () -> Bool = { true },
        identify: @Sendable (URL) async throws -> MediaInputIdentity = { try await MediaInputIdentityService.shared.identify($0) }
    ) async throws {
        let context = preparationContext
        try Task.checkCancellation()
        guard validate() else { throw CancellationError() }
        inputIdentityVerified = false
        let attempt = UUID()
        identityPreparationAttempt = attempt
        defer {
            if identityPreparationAttempt == attempt { identityPreparationAttempt = nil }
        }
        let identity = try await identify(context.sourceURL)
        try Task.checkCancellation()
        guard preparationContext == context, validate(), identityPreparationAttempt == attempt else { throw CancellationError() }
        guard identity.isValid else { throw CocoaError(.fileReadCorruptFile) }
        inputIdentity = identity
        inputIdentityVerified = true
    }

    func relocate(to newURL: URL) {
        let identity = inputIdentity
        url = newURL
        inputIdentity = identity
    }

    func loadLibraryThumbnail(load: MediaAssetMetadata.Loader = MediaAssetMetadata.load) async {
        let context = preparationContext
        switch type {
        case .image:
            await loadImageThumbnail(maxPixelSize: ImageEncoder.libraryThumbnailMaxPixelSize, load: load)
        case .video, .lottie:
            guard thumbnail == nil, await acquireThumbnailPermit() else { return }
            defer { releaseThumbnailPermit() }
            guard thumbnail == nil, !Task.isCancelled, preparationContext == context else { return }
            _ = await loadMetadata(load: load)
        case .audio, .text, .sequence, .subtitle, .html:
            break
        }
    }

    func loadPreviewThumbnail(load: MediaAssetMetadata.Loader = MediaAssetMetadata.load) async {
        guard type == .image else { return }
        await loadImageThumbnail(maxPixelSize: ImageEncoder.maxLongestEdge, load: load)
    }

    func installThumbnail(_ image: CGImage, maximumPixelSize: Int) {
        guard maximumPixelSize >= thumbnailMaxPixelSize else { return }
        thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        thumbnailMaxPixelSize = maximumPixelSize
    }

    @discardableResult
    func loadMetadata(
        includeThumbnail: Bool = true,
        load: MediaAssetMetadata.Loader = MediaAssetMetadata.load,
        validate: @MainActor () -> Bool = { true }
    ) async -> Bool {
        let context = preparationContext
        do {
            let metadata = try await readMetadata(
                thumbnailMaxPixelSize: includeThumbnail ? ImageEncoder.maxLongestEdge : nil,
                load: load, validate: validate
            )
            guard !Task.isCancelled, preparationContext == context, validate() else { return false }
            applyMetadata(metadata)
            return metadata.isReadable
        } catch {
            return false
        }
    }

    struct PreparationContext: Equatable {
        let sourceURL: URL
        let sourceRevision: UUID
        let backendJobId: String?
        let outputIndex: Int?
        let isGenerated: Bool
        let status: GenerationStatus
        let importInput: MediaImportInput?
    }

    var preparationContext: PreparationContext {
        PreparationContext(
            sourceURL: url, sourceRevision: inputIdentityRevision, backendJobId: generationInput?.backendJobId,
            outputIndex: generationInput?.outputIndex, isGenerated: isGenerated,
            status: generationStatus, importInput: importInput
        )
    }

    func readMetadata(
        thumbnailMaxPixelSize: Int?,
        load: MediaAssetMetadata.Loader = MediaAssetMetadata.load,
        validate: @MainActor () -> Bool = { true }
    ) async throws -> MediaAssetMetadata {
        let context = preparationContext
        let request = MediaAssetMetadata.Request(url: url, type: type, thumbnailMaxPixelSize: thumbnailMaxPixelSize)
        func check() throws {
            try Task.checkCancellation()
            guard self.preparationContext == context, validate() else { throw CancellationError() }
        }
        try check()
        try await Self.metadataLoadGate.wait()
        let metadata: MediaAssetMetadata
        do {
            try check()
            metadata = try await load(request)
            try check()
        } catch {
            await Self.metadataLoadGate.signal()
            throw error
        }
        await Self.metadataLoadGate.signal()
        try check()
        return metadata
    }

    func applyMetadata(_ metadata: MediaAssetMetadata) {
        if let value = metadata.duration { duration = value }
        if let value = metadata.width { sourceWidth = value }
        if let value = metadata.height { sourceHeight = value }
        if let value = metadata.framesPerSecond { sourceFPS = value }
        if let value = metadata.hasAudio { hasAudio = value }
        if let image = metadata.thumbnail, let maximumPixelSize = metadata.thumbnailMaxPixelSize {
            installThumbnail(image, maximumPixelSize: maximumPixelSize)
        }
    }

    private func loadImageThumbnail(maxPixelSize: Int, load: MediaAssetMetadata.Loader) async {
        let context = preparationContext
        guard maxPixelSize > thumbnailMaxPixelSize, await acquireThumbnailPermit() else { return }
        defer { releaseThumbnailPermit() }
        guard maxPixelSize > thumbnailMaxPixelSize, !Task.isCancelled,
              preparationContext == context else { return }
        do {
            let metadata = try await readMetadata(thumbnailMaxPixelSize: maxPixelSize, load: load)
            guard !Task.isCancelled, preparationContext == context,
                  maxPixelSize > thumbnailMaxPixelSize else { return }
            applyMetadata(metadata)
        } catch {
            return
        }
    }

    private func acquireThumbnailPermit() async -> Bool {
        do {
            try await Self.thumbnailLoadGate.wait()
            return true
        } catch {
            return false
        }
    }

    private func releaseThumbnailPermit() {
        Task { await Self.thumbnailLoadGate.signal() }
    }
}
