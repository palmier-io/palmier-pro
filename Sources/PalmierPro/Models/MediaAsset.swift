import AppKit
import AVFoundation

@Observable
@MainActor
final class MediaAsset: Identifiable {
    let id: String
    let url: URL
    let type: ClipType
    let name: String
    var duration: Double
    var thumbnail: NSImage?
    var generationInput: GenerationInput?
    var generationStatus: GenerationStatus = .none

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
    }

    /// Reconstruct from a manifest entry + resolved URL.
    convenience init(entry: MediaManifestEntry, resolvedURL: URL) {
        self.init(id: entry.id, url: resolvedURL, type: entry.type, name: entry.name, duration: entry.duration, generationInput: entry.generationInput)
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
        return MediaManifestEntry(id: id, name: name, type: type, source: source, duration: duration, generationInput: generationInput)
    }

    func loadMetadata() async {
        if type == .image {
            duration = Defaults.imageDurationSeconds
            thumbnail = NSImage(contentsOf: url)
            return
        }

        let avAsset = AVURLAsset(url: url)
        if let d = try? await avAsset.load(.duration) {
            duration = d.seconds
        }
        if type == .video {
            let gen = AVAssetImageGenerator(asset: avAsset)
            gen.maximumSize = CGSize(width: 160, height: 90)
            gen.appliesPreferredTrackTransform = true
            if let cgImage = try? await gen.image(at: .zero).image {
                thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: 160, height: 90))
            }
        }
    }
}
