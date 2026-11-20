import Darwin
import Foundation

struct ProjectPackageCleanupError: LocalizedError {
    let operationError: Error
    let cleanupError: Error

    var errorDescription: String? {
        "\(operationError.localizedDescription) Cleanup failed: \(cleanupError.localizedDescription)"
    }
}

final class ProjectPackageIO: Sendable {
    private let queue = DispatchQueue(label: "compositor.project-package-io", qos: .utility)

    func perform<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    func write<T: Sendable>(_ operation: @Sendable () throws -> T) throws -> T {
        guard !Thread.isMainThread else { throw CocoaError(.fileWriteUnknown) }
        dispatchPrecondition(condition: .notOnQueue(queue))
        return try queue.sync(execute: operation)
    }

    func prepare(_ stagedURL: URL, for packageURL: URL, maxBytes: Int64?) async throws -> URL {
        try await perform {
            let fm = FileManager.default
            let values = try stagedURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, size > 0 else { throw CocoaError(.fileReadCorruptFile) }
            if let maxBytes {
                guard maxBytes > 0 else { throw CocoaError(.fileWriteInvalidFileName) }
                if Int64(size) > maxBytes {
                    throw FileIOError.fileTooLarge(size: Int64(size), maxBytes: maxBytes)
                }
            }
            let prepared = packageURL.deletingLastPathComponent()
                .appendingPathComponent(".compositor-stage-\(UUID().uuidString)")
            do {
                try fm.copyItem(at: stagedURL, to: prepared)
                return prepared
            } catch {
                do { try Self.removeIfPresent(prepared) }
                catch let cleanup { throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup) }
                throw error
            }
        }
    }

    func reservePackage(at destination: URL) async throws {
        try await perform {
            let fm = FileManager.default
            let parent = destination.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let staged = parent.appendingPathComponent(".compositor-new-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: staged, withIntermediateDirectories: false)
            do {
                try Self.moveExclusively(staged, to: destination)
            } catch {
                do { try Self.removeIfPresent(staged) }
                catch let cleanup { throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup) }
                if let failure = error as? CocoaError, failure.code == .fileWriteFileExists {
                    throw ProjectError.nameTaken(destination)
                }
                throw error
            }
        }
    }

    func install(_ preparedURL: URL, to destination: URL) async throws {
        try await perform {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.moveExclusively(preparedURL, to: destination)
        }
    }

    private static func moveExclusively(_ source: URL, to destination: URL) throws {
        guard source.isFileURL, destination.isFileURL else { throw CocoaError(.fileWriteInvalidFileName) }
        try source.withUnsafeFileSystemRepresentation { from in
            try destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { throw CocoaError(.fileWriteInvalidFileName) }
                guard renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 else {
                    let code = errno
                    let failure = NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                    if code == EEXIST {
                        throw CocoaError(.fileWriteFileExists, userInfo: [NSUnderlyingErrorKey: failure])
                    }
                    throw failure
                }
            }
        }
    }

    func remove(_ urls: [URL]) async throws {
        try await perform {
            var firstError: Error?
            for url in Set(urls) {
                do { try Self.removeIfPresent(url) }
                catch { if firstError == nil { firstError = error } }
            }
            if let firstError { throw firstError }
        }
    }

    private static func removeIfPresent(_ url: URL) throws {
        do { try FileManager.default.removeItem(at: url) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    }
}
