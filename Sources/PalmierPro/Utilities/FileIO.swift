import Foundation

enum FileIOError: LocalizedError {
    case fileTooLarge(size: Int64, maxBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let size, let maxBytes):
            "file exceeds max size (\(size) > \(maxBytes) bytes)"
        }
    }
}

enum FileIO {
    nonisolated static func temporaryFileURL(pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("palmier-stage-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }

    nonisolated static func stageData(_ data: Data, pathExtension: String) throws -> URL {
        let url = temporaryFileURL(pathExtension: pathExtension)
        try data.write(to: url, options: .atomic)
        return url
    }

    nonisolated static func prepareStagedFile(from stagedURL: URL, nextTo packageURL: URL, maxBytes: Int64? = nil) throws -> URL {
        let fm = FileManager.default
        let directory = packageURL.deletingLastPathComponent()
        let preparedURL = directory.appendingPathComponent(".palmier-stage-\(UUID().uuidString)")
        do {
            try copyReplacingDestination(from: stagedURL, to: preparedURL, maxBytes: maxBytes)
            return preparedURL
        } catch {
            try? fm.removeItem(at: preparedURL)
            throw error
        }
    }

    nonisolated static func installPreparedFile(from preparedURL: URL, to destinationURL: URL) throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: preparedURL) }
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destinationURL.path) {
            _ = try fm.replaceItemAt(destinationURL, withItemAt: preparedURL)
        } else {
            try fm.moveItem(at: preparedURL, to: destinationURL)
        }
    }

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

    @discardableResult
    nonisolated static func copyReplacingDestination(
        from sourceURL: URL,
        to destinationURL: URL,
        maxBytes: Int64? = nil
    ) throws -> Int64 {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sourceSize = (try? fm.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if let maxBytes, sourceSize > maxBytes {
            throw FileIOError.fileTooLarge(size: sourceSize, maxBytes: maxBytes)
        }
        if fm.fileExists(atPath: destinationURL.path) {
            try fm.removeItem(at: destinationURL)
        }
        try fm.copyItem(at: sourceURL, to: destinationURL)
        return sourceSize
    }
}
