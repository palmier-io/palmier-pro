import AppKit
import AVFoundation

@Observable
@MainActor
final class MediaAsset: Identifiable {
    let id: String
    var url: URL
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
    var generationStatus: GenerationStatus = .none
    var folderId: String?
    var pendingDownloadURL: URL?
    var cachedRemoteURL: String?
    var cachedRemoteURLExpiresAt: Date?

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
    var generatingLabel: String {
        switch generationStatus {
        case .preparing: "Preparing..."
        case .downloading: "Downloading..."
        case .rendering: "Rendering..."
        default: "Generating..."
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
        let restoredStatus = GenerationStatus(serialized: entry.generationStatus)
        self.generationStatus = restoredStatus == .preparing && !canResumeGeneration ? .none : restoredStatus
    }

    /// Produce a serializable manifest entry from this asset.
    func toManifestEntry(projectURL: URL?) -> MediaManifestEntry {
        let source: MediaSource
        if let projectURL, url.path.hasPrefix(projectURL.path) {
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
        )
    }

    func loadMetadata() async {
        if type == .image {
            duration = Defaults.imageDurationSeconds
            let imageURL = url
            let metadata = await Task.detached(priority: .utility) {
                ImageEncoder.metadata(url: imageURL, thumbnailMaxPixelSize: 1568)
            }.value
            if let width = metadata.width { sourceWidth = width }
            if let height = metadata.height { sourceHeight = height }
            if let image = metadata.thumbnail {
                thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
            return
        }

        if type == .lottie {
            guard let info = try? await LottieVideoGenerator.inspect(fileAt: url) else { return }
            duration = info.meta.duration
            sourceWidth = Int(info.meta.size.width)
            sourceHeight = Int(info.meta.size.height)
            sourceFPS = info.meta.framerate
            if let cg = info.thumbnail {
                thumbnail = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            return
        }

        let avAsset = AVURLAsset(url: url)
        if type != .video, let d = try? await avAsset.load(.duration) {
            duration = d.seconds
        }
        if type == .video {
            var videoDuration: Double?
            var hasVideoTrack = false
            if let videoTrack = try? await avAsset.loadTracks(withMediaType: .video).first {
                hasVideoTrack = true
                if let size = try? await videoTrack.load(.naturalSize),
                   let transform = try? await videoTrack.load(.preferredTransform) {
                    let corrected = size.applying(transform)
                    sourceWidth = Int(abs(corrected.width))
                    sourceHeight = Int(abs(corrected.height))
                }
                if let rate = try? await videoTrack.load(.nominalFrameRate), rate > 0 {
                    sourceFPS = Double(rate)
                }
                videoDuration = (try? await videoTrack.load(.timeRange))?.duration.seconds
            }
            if let videoDuration {
                duration = videoDuration
            } else if let d = try? await avAsset.load(.duration) {
                duration = d.seconds
            }
            if let audioTracks = try? await avAsset.loadTracks(withMediaType: .audio) {
                hasAudio = !audioTracks.isEmpty
            }
            if hasVideoTrack {
                let gen = AVAssetImageGenerator(asset: avAsset)
                gen.maximumSize = CGSize(width: 320, height: 320)   // square budget — portrait gets full res too
                gen.appliesPreferredTrackTransform = true
                if let cgImage = try? await gen.image(at: .zero).image {
                    // Use the generated frame's true pixel size — a hardcoded 16:9 size makes
                    // SwiftUI's aspectRatio squeeze non-16:9 (e.g. vertical) thumbnails.
                    thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                }
            }
        }
    }
}
