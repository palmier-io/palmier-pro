import Foundation

enum ImageConverter {
    struct ConversionError: LocalizedError {
        let filename: String

        var errorDescription: String? {
            "Could not convert reference image \(filename) to JPEG."
        }
    }

    nonisolated static func requiresConversion(_ url: URL) -> Bool {
        ["heic", "heif"].contains(url.pathExtension.lowercased())
    }

    @concurrent
    static func convertToJPEG(_ url: URL) async throws -> URL {
        try Task.checkCancellation()
        let metadata = ImageEncoder.metadata(url: url)
        guard let width = metadata.width,
              let height = metadata.height,
              let image = ImageEncoder.thumbnail(url: url, maxPixelSize: max(width, height)),
              let data = ImageEncoder.encodeJPEG(image, quality: 0.92) else {
            throw ConversionError(filename: url.lastPathComponent)
        }

        let outputURL = FileIO.temporaryFileURL(pathExtension: "jpg")
        do {
            try data.write(to: outputURL, options: .atomic)
            try Task.checkCancellation()
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    @concurrent
    static func removeConvertedFile(_ url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }
}
