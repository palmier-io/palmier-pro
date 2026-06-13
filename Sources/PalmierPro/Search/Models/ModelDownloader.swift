import CoreML
import CryptoKit
import Foundation

/// Downloads, verifies, compiles, and installs the search encoders under Application Support.
/// Layout: Models/<model>-v<version>/{ImageEncoder.mlmodelc, TextEncoder.mlmodelc, tokenizer/, spec.json}
final class ModelDownloader: @unchecked Sendable {
    struct Manifest: Codable, Sendable {
        struct File: Codable, Sendable {
            let name: String
            let sha256: String
            let bytes: Int64
        }
        struct Files: Codable, Sendable {
            let imageEncoder: File
            let textEncoder: File
            let tokenizer: File
        }
        let model: String
        let version: Int
        let embeddingDim: Int
        let imageSize: Int
        let contextLength: Int
        let files: Files

        var spec: VisualEmbedder.Spec {
            .init(model: model, version: version, embeddingDim: embeddingDim,
                  imageSize: imageSize, contextLength: contextLength)
        }
    }

    struct InstalledModel: Sendable {
        let imageEncoderURL: URL
        let textEncoderURL: URL
        let tokenizerFolder: URL
        let spec: VisualEmbedder.Spec
    }

    enum DownloadError: Error {
        case httpError(Int, String)
        case checksumMismatch(String)
        case unzipFailed
        case missingPackage(String)
    }

    static let modelsDir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PalmierPro/Models")

    static func installDir(for manifest: Manifest) -> URL {
        modelsDir.appendingPathComponent("\(manifest.model)-v\(manifest.version)")
    }

    static func installed(for manifest: Manifest) -> InstalledModel? {
        let dir = installDir(for: manifest)
        let image = dir.appendingPathComponent("ImageEncoder.mlmodelc")
        let text = dir.appendingPathComponent("TextEncoder.mlmodelc")
        let tokenizer = dir.appendingPathComponent("tokenizer", isDirectory: true)
        guard FileManager.default.fileExists(atPath: image.path),
              FileManager.default.fileExists(atPath: text.path),
              FileManager.default.fileExists(atPath: tokenizer.appendingPathComponent("tokenizer.json").path)
        else { return nil }
        return InstalledModel(imageEncoderURL: image, textEncoderURL: text, tokenizerFolder: tokenizer, spec: manifest.spec)
    }

    /// Idempotent: returns immediately if already installed. `progress` is 0...1 across both files.
    func install(
        manifest: Manifest,
        baseURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> InstalledModel {
        if let existing = Self.installed(for: manifest) { return existing }

        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("palmier-model-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let files = [manifest.files.imageEncoder, manifest.files.textEncoder, manifest.files.tokenizer]
        let totalBytes = files.reduce(0) { $0 + $1.bytes }
        var doneBytes: Int64 = 0
        var staged: [String: URL] = [:]

        for file in files {
            let base = Double(doneBytes)
            let zipURL = try await download(baseURL.appendingPathComponent(file.name), to: staging) { fileFraction in
                progress?((base + fileFraction * Double(file.bytes)) / Double(totalBytes))
            }
            try Self.verify(zipURL, sha256: file.sha256)
            let extracted = try Self.unzip(zipURL, in: staging)
            // Encoder zips contain an .mlpackage to compile; the tokenizer zip is plain files.
            if extracted.pathExtension == "mlpackage" {
                staged[file.name] = try await MLModel.compileModel(at: extracted)
            } else {
                staged[file.name] = extracted
            }
            doneBytes += file.bytes
            progress?(Double(doneBytes) / Double(totalBytes))
        }

        let dir = Self.installDir(for: manifest)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.moveItem(at: staged[manifest.files.imageEncoder.name]!,
                        to: dir.appendingPathComponent("ImageEncoder.mlmodelc"))
        try fm.moveItem(at: staged[manifest.files.textEncoder.name]!,
                        to: dir.appendingPathComponent("TextEncoder.mlmodelc"))
        try fm.moveItem(at: staged[manifest.files.tokenizer.name]!,
                        to: dir.appendingPathComponent("tokenizer", isDirectory: true))
        try JSONEncoder().encode(manifest.spec).write(to: dir.appendingPathComponent("spec.json"))

        guard let installed = Self.installed(for: manifest) else { throw DownloadError.unzipFailed }
        return installed
    }

    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let onProgress: @Sendable (Double) -> Void
        init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {}

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    private func download(
        _ url: URL,
        to dir: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let delegate = ProgressDelegate(onProgress: progress)
        let (temp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.httpError(http.statusCode, url.lastPathComponent)
        }
        let dest = dir.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: temp, to: dest)
        return dest
    }

    static func verify(_ url: URL, sha256 expected: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expected else { throw DownloadError.checksumMismatch(url.lastPathComponent) }
    }

    private static func unzip(_ zipURL: URL, in dir: URL) throws -> URL {
        let out = dir.appendingPathComponent(zipURL.deletingPathExtension().lastPathComponent + "-extracted")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, out.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw DownloadError.unzipFailed }
        // Each zip contains exactly one top-level entry (.mlpackage or tokenizer/).
        let entries = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
        guard let entry = entries.first, entries.count == 1 else {
            throw DownloadError.missingPackage(zipURL.lastPathComponent)
        }
        return entry
    }
}
