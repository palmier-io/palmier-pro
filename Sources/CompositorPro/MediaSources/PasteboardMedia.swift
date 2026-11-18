import AppKit
import Foundation
import UniformTypeIdentifiers

/// Media the user pasted: file URLs from Finder/other apps, or raw image bytes copied from a
/// screenshot tool or image editor.
enum PastedMedia: Sendable, Equatable {
    case file(URL, ClipType)
    case imageData(Data)
}

enum PasteboardMedia {
    private static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]

    /// Supported media on the pasteboard, in paste order. Non-media pasteboard content yields [].
    @MainActor
    static func readable(from pasteboard: NSPasteboard) -> [PastedMedia] {
        var results: [PastedMedia] = []
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] {
            for url in urls {
                guard let type = ClipType(fileExtension: url.pathExtension.lowercased()) else { continue }
                results.append(.file(url, type))
            }
        }
        if results.isEmpty {
            for type in imageTypes {
                if let data = pasteboard.data(forType: type), !data.isEmpty {
                    results.append(.imageData(data))
                    break
                }
            }
        }
        return results
    }

    /// Writes pasted image bytes to a temp file so the normal import pipeline can take over.
    @concurrent
    static func stageImageData(_ data: Data, into directory: URL) async throws -> URL {
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let url = directory.appendingPathComponent("pasted-\(UUID().uuidString).png", isDirectory: false)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard NSBitmapImageRep(data: data) != nil else { throw CocoaError(.fileReadCorruptFile) }
        try data.write(to: url, options: .atomic)
        return url
    }
}
