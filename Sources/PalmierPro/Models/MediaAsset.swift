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

    init(id: String = UUID().uuidString, url: URL, type: ClipType, name: String, duration: Double = 0, thumbnail: NSImage? = nil) {
        self.id = id
        self.url = url
        self.type = type
        self.name = name
        self.duration = duration
        self.thumbnail = thumbnail
    }

    /// Reconstruct from a manifest entry + resolved URL.
    convenience init(entry: MediaManifestEntry, resolvedURL: URL) {
        self.init(id: entry.id, url: resolvedURL, type: entry.type, name: entry.name, duration: entry.duration)
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
        return MediaManifestEntry(id: id, name: name, type: type, source: source, duration: duration)
    }

    func loadMetadata() async {
        let avAsset = AVURLAsset(url: url)
        if type == .video || type == .audio {
            if let d = try? await avAsset.load(.duration) {
                duration = d.seconds
            }
        }
        if type == .image {
            thumbnail = NSImage(contentsOf: url)
        } else if type == .video {
            let gen = AVAssetImageGenerator(asset: avAsset)
            gen.maximumSize = CGSize(width: 160, height: 90)
            gen.appliesPreferredTrackTransform = true
            if let cgImage = try? await gen.image(at: .zero).image {
                thumbnail = NSImage(cgImage: cgImage, size: NSSize(width: 160, height: 90))
            }
        }
    }
}
