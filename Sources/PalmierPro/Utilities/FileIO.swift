import Foundation

enum FileIOError: LocalizedError {
    case fileTooLarge(size: Int64, maxBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let size, let maxBytes):
            "downloaded file exceeds max size (\(size) > \(maxBytes) bytes)"
        }
    }
}

enum FileIO {
    nonisolated static func writeData(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    @discardableResult
    nonisolated static func moveReplacingDestination(
        from tempURL: URL,
        to destinationURL: URL,
        maxBytes: Int64? = nil
    ) throws -> Int64 {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: tempURL) }
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let downloadedSize = (try? fm.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let maxBytes, downloadedSize > maxBytes {
            throw FileIOError.fileTooLarge(size: downloadedSize, maxBytes: maxBytes)
        }
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.moveItem(at: tempURL, to: destinationURL)
        return downloadedSize
    }
}
