import AppKit
import AVFoundation

@Observable
@MainActor
final class MediaAsset: Identifiable {
    let id: String
    let url: URL
    let type: ClipType
    var name: String
    var duration: Double
    var thumbnail: NSImage?
    var sourceWidth: Int?
    var sourceHeight: Int?
    var sourceFPS: Double?
    var hasAudio: Bool = false
    var generationInput: GenerationInput?
    var generationStatus: GenerationStatus = .none
    var parentAssetId: String?

    enum GenerationStatus: Equatable {
        case none
        case generating
        case failed(String)
    }

    var isGenerated: Bool { generationInput != nil }
    var isGenerating: Bool { generationStatus == .generating }

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
        self.parentAssetId = entry.parentAssetId
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
        return MediaManifestEntry(id: id, name: name, type: type, source: source, duration: duration, generationInput: generationInput, sourceWidth: sourceWidth, sourceHeight: sourceHeight, sourceFPS: sourceFPS, hasAudio: hasAudio, parentAssetId: parentAssetId)
    }

    func loadMetadata() async {
        if type == .image {
            duration = Defaults.imageDurationSeconds
            thumbnail = NSImage(contentsOf: url)
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                sourceWidth = props[kCGImagePropertyPixelWidth] as? Int
                sourceHeight = props[kCGImagePropertyPixelHeight] as? Int
            }
            return
        }

        let avAsset = AVURLAsset(url: url)
        if let d = try? await avAsset.load(.duration) {
            duration = d.seconds
        }
        if type == .video {
            if let videoTrack = try? await avAsset.loadTracks(withMediaType: .video).first {
                if let size = try? await videoTrack.load(.naturalSize),
                   let transform = try? await videoTrack.load(.preferredTransform) {
                    let corrected = size.applying(transform)
                    sourceWidth = Int(abs(corrected.width))
                    sourceHeight = Int(abs(corrected.height))
                }
                if let rate = try? await videoTrack.load(.nominalFrameRate), rate > 0 {
                    sourceFPS = Double(rate)
                }
            }
            if let audioTracks = try? await avAsset.loadTracks(withMediaType: .audio) {
                hasAudio = !audioTracks.isEmpty
            }
            let gen = AVAssetImageGenerator(asset: avAsset)
            gen.maximumSize = CGSize(width: 160, height: 90)
            gen.appliesPreferredTrackTransform = true
            if let cgImage = try? await gen.image(at: .zero).image {
                thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: 160, height: 90))
            }
        }
    }
}
