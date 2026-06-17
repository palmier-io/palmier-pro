import AppKit
import Foundation

@MainActor
@Observable
final class SampleProjectService {
    static let shared = SampleProjectService()

    struct Summary: Identifiable, Decodable, Sendable {
        let slug: String
        let title: String
        let posterUrl: String?
        var id: String { slug }
    }

    private struct Download: Sendable {
        let id: String
        let relativePath: String
        let url: URL
    }

    enum SampleError: LocalizedError {
        case notConfigured
        case http(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .notConfigured: "Backend not configured."
            case .http(let code): "Server returned HTTP \(code)."
            case .malformed: "The sample response was malformed."
            }
        }
    }

    private var baseURL: URL? { BackendConfig.convexHttpURL }

    // MARK: - Listing

    func fetchSamples() async throws -> [Summary] {
        guard let base = baseURL else { throw SampleError.notConfigured }
        let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("v1/samples"))
        try Self.throwIfHTTPError(response)
        return try JSONDecoder().decode([Summary].self, from: data)
    }

    // MARK: - Materialization

    /// Builds a new `.palmier` package for `slug` and returns its URL. Reports
    /// download progress (0...1) on the main actor. Cleans up a partial package
    /// if anything fails.
    func materialize(slug: String, onProgress: @escaping (Double) -> Void) async throws -> URL {
        guard let base = baseURL else { throw SampleError.notConfigured }

        var components = URLComponents(
            url: base.appendingPathComponent("v1/samples/resolve"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "slug", value: slug)]
        guard let url = components?.url else { throw SampleError.malformed }

        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.throwIfHTTPError(response)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = root["title"] as? String,
              let project = root["project"],
              let manifest = root["manifest"],
              let rawDownloads = root["downloads"] as? [[String: Any]]
        else { throw SampleError.malformed }

        var downloads: [Download] = try rawDownloads.map { entry in
            guard let id = entry["id"] as? String,
                  let relativePath = entry["relativePath"] as? String,
                  let urlString = entry["url"] as? String,
                  let assetURL = URL(string: urlString)
            else { throw SampleError.malformed }
            return Download(id: id, relativePath: relativePath, url: assetURL)
        }
        for entry in root["chat"] as? [[String: Any]] ?? [] {
            guard let name = entry["name"] as? String,
                  let urlString = entry["url"] as? String,
                  let chatURL = URL(string: urlString)
            else { throw SampleError.malformed }
            downloads.append(Download(id: name, relativePath: "\(ChatSessionStore.dirName)/\(name)", url: chatURL))
        }

        let projectData = try JSONSerialization.data(withJSONObject: project)
        let manifestData = try JSONSerialization.data(withJSONObject: manifest)

        let fm = FileManager.default
        let slugDir = Self.cacheSlugDir(slug: slug)
        try? fm.removeItem(at: slugDir)   // clear any stale/partial copy before re-downloading
        let dest = slugDir.appendingPathComponent("\(Self.safeName(title)).\(Project.fileExtension)")
        let mediaDir = dest.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)

        do {
            try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
            try projectData.write(to: dest.appendingPathComponent(Project.timelineFilename))
            try manifestData.write(to: dest.appendingPathComponent(Project.manifestFilename))
            if let log = root["generationLog"], !(log is NSNull) {
                try JSONSerialization.data(withJSONObject: log)
                    .write(to: dest.appendingPathComponent(Project.generationLogFilename))
            }

            if let posterString = root["posterUrl"] as? String, let posterURL = URL(string: posterString) {
                try? await Self.downloadFile(from: posterURL, to: dest.appendingPathComponent(Project.thumbnailFilename))
            }

            // Download every package file (media + chat transcript) concurrently.
            let total = max(1, downloads.count)
            var completed = 0
            onProgress(0)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for download in downloads {
                    group.addTask {
                        try await Self.downloadFile(
                            from: download.url, to: dest.appendingPathComponent(download.relativePath)
                        )
                    }
                }
                for try await _ in group {
                    completed += 1
                    onProgress(Double(completed) / Double(total))
                }
            }
        } catch {
            try? fm.removeItem(at: slugDir)
            Log.project.error("materialize sample failed slug=\(slug) error=\(error.localizedDescription)")
            throw error
        }

        Log.project.notice("materialized sample slug=\(slug) at \(dest.lastPathComponent)")
        return dest
    }

    // MARK: - Helpers

    nonisolated private static func throwIfHTTPError(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else { throw SampleError.http(http.statusCode) }
    }

    /// Download `url` to `target`, creating parent dirs and replacing any existing file.
    nonisolated private static func downloadFile(from url: URL, to target: URL) async throws {
        let (tmp, response) = try await URLSession.shared.download(from: url)
        try throwIfHTTPError(response)
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: tmp, to: target)
    }

    func cachedURL(slug: String) -> URL? {
        let dir = Self.cacheSlugDir(slug: slug)
        let contents = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        return contents?.first { $0.pathExtension == Project.fileExtension }
    }

    private static func cacheSlugDir(slug: String) -> URL {
        cacheRoot().appendingPathComponent(safeName(slug), isDirectory: true)
    }

    private static func cacheRoot() -> URL {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PalmierPro/Samples", isDirectory: true)
    }

    private static func safeName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let cleaned = name.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Sample" : cleaned
    }
}
