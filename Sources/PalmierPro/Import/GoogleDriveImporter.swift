import Foundation
import AppKit

// MARK: - Models

struct GDriveFileEntry: Codable, Sendable {
    let id: String
    let name: String
    let mimeType: String
    let size: Int
}

/// Errors that can occur during a Google Drive import flow.
enum GDriveError: LocalizedError {
    case invalidFolderUrl
    case notSignedIn
    case fetchFailed(String)
    case downloadFailed(String)
    case importFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidFolderUrl: return "Invalid Google Drive folder URL"
        case .notSignedIn: return "Sign in to import from Google Drive."
        case .fetchFailed(let msg): return "Failed to list files: \(msg)"
        case .downloadFailed(let msg): return "Failed to download file: \(msg)"
        case .importFailed(let msg): return "Failed to import file: \(msg)"
        }
    }
}

// MARK: - MIME type → file extension mapping

/// Maps a Drive MIME type to a file extension using the shared import mapping.
private func fileExtension(forMime mime: String) -> String? {
    ToolExecutor.fileExtension(forMime: mime)
}

/// Supported media MIME categories.
private let supportedVideoMimes: Set<String> = ["video/mp4", "video/mpeg4", "video/quicktime"]
private let supportedAudioMimes: Set<String> = ["audio/mpeg", "audio/mp3", "audio/wav", "audio/x-wav", "audio/wave", "audio/aac", "audio/mp4", "audio/m4a", "audio/x-m4a", "audio/flac", "audio/x-flac"]
private let supportedImageMimes: Set<String> = ["image/jpeg", "image/jpg", "image/png", "image/webp", "image/heic", "image/heif", "image/tiff"]

func isSupportedMediaMime(_ mime: String) -> Bool {
    let lower = mime.lowercased()
    return supportedVideoMimes.contains(lower)
        || supportedAudioMimes.contains(lower)
        || supportedImageMimes.contains(lower)
}

// MARK: - GoogleDriveImporter

/// Service for importing media files from a Google Drive shared folder.
///
/// Flow:
/// 1. User pastes a Drive folder URL → `listFolder()` calls a Supabase Edge Function
///    which resolves the folder via a GCP Service Account and returns file entries.
/// 2. Each file is downloaded via the `gdrive-download` Supabase Edge Function that
///    proxies bytes using the service account — no client-side Google auth needed.
/// 3. Files are saved into the project's media directory and registered with
///    `EditorViewModel`.
@MainActor
final class GoogleDriveImporter {
    static let shared = GoogleDriveImporter()

    private init() {}

    /// Max bytes for a single download (2 GB).
    private static let maxDownloadBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// The edge functions reject the anon key; they require a signed-in user's token.
    private func userAccessToken() async throws -> String {
        guard let session = try? await SupabaseService.shared.client.auth.session else {
            throw GDriveError.notSignedIn
        }
        return session.accessToken
    }

    /// Download timeout in seconds.
    private static let downloadTimeout: TimeInterval = 300

    // MARK: - List Folder

    /// Lists all media files in the given Google Drive shared folder by calling
    /// the Supabase Edge Function.
    func listFolder(_ folderUrl: String) async throws -> [GDriveFileEntry] {
        let url = SupabaseConfig.url
            .appendingPathComponent("functions/v1")
            .appendingPathComponent("gdrive-list")

        let accessToken = try await userAccessToken()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let body: [String: String] = ["folderUrl": folderUrl]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        Log.project.notice("GDrive: listing folder via edge function url=\(folderUrl)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResp = response as? HTTPURLResponse else {
            throw GDriveError.fetchFailed("No HTTP response")
        }
        guard (200..<300).contains(httpResp.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? "(empty)"
            throw GDriveError.fetchFailed("HTTP \(httpResp.statusCode): \(bodyStr)")
        }

        struct ListResponse: Decodable {
            let files: [GDriveFileEntry]
        }

        let decoded = try JSONDecoder().decode(ListResponse.self, from: data)
        let supported = decoded.files.filter { isSupportedMediaMime($0.mimeType) }
        Log.project.notice(
            "GDrive: listed \(decoded.files.count) files, \(supported.count) supported"
        )
        return supported
    }

    // MARK: - Download Single File

    /// Downloads a single file from Google Drive and saves it to the given local URL.
    /// Proxies the download through the `gdrive-download` Supabase Edge Function, which
    /// authenticates to Drive with the service account and streams the bytes back.
    func downloadFile(entry: GDriveFileEntry, to destURL: URL) async throws {
        guard let _ = fileExtension(forMime: entry.mimeType) else {
            throw GDriveError.downloadFailed("Unsupported MIME type: \(entry.mimeType)")
        }

        Log.project.notice("GDrive: downloading file=\(entry.name) id=\(entry.id)")

        // Check remaining disk space before downloading.
        let fileManager = FileManager.default
        let mediaDir = destURL.deletingLastPathComponent()
        if let freeBytes = try? mediaDir.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity {
            let needed = Int64(clamping: entry.size) * 2
            if freeBytes < needed {
                throw GDriveError.downloadFailed(
                    "Not enough disk space to download '\(entry.name)' "
                    + "(need ~\(needed / (1024*1024)) MB, have \(freeBytes / (1024*1024)) MB free)"
                )
            }
        }

        let url = SupabaseConfig.url
            .appendingPathComponent("functions/v1")
            .appendingPathComponent("gdrive-download")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.downloadTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let accessToken = try await userAccessToken()
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["fileId": entry.id])

        let delegate = ImportDownloadDelegate(maxBytes: Self.maxDownloadBytes)
        let (tempURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)

        guard let httpResp = response as? HTTPURLResponse, (200..<300).contains(httpResp.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            try? FileManager.default.removeItem(at: tempURL)
            throw GDriveError.downloadFailed("Server returned HTTP \(code)")
        }

        // Verify file size sanity.
        let downloadedSize = (try? fileManager.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        if downloadedSize > Self.maxDownloadBytes {
            try? fileManager.removeItem(at: tempURL)
            throw GDriveError.downloadFailed("Downloaded file exceeds 2 GB limit")
        }

        // Move to final destination.
        try? fileManager.removeItem(at: destURL)
        try fileManager.moveItem(at: tempURL, to: destURL)

        Log.project.notice(
            "GDrive: downloaded file=\(entry.name) size=\(downloadedSize) bytes"
        )
    }

    // MARK: - Import into Project

    /// Downloads all files from a Drive folder and imports them into the current project.
    /// Returns the count of successfully imported files.
    /// - Parameters:
    ///   - editor: The active EditorViewModel.
    ///   - entries: File entries returned by `listFolder`.
    ///   - folderId: Optional destination media folder ID.
    ///   - progressHandler: Optional callback invoked after each file is downloaded/imported.
    /// - Returns: Number of successfully imported media assets.
    func importIntoProject(
        editor: EditorViewModel,
        entries: [GDriveFileEntry],
        folderId: String?,
        progressHandler: ((String) -> Void)? = nil
    ) async throws -> Int {
        guard let projectURL = editor.projectURL else {
            Log.project.error("GDrive: import failed — no project open")
            throw GDriveError.importFailed("No project is open")
        }

        let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        } catch {
            Log.project.error("GDrive: cannot create media directory: \(error.localizedDescription)")
            throw GDriveError.importFailed("Cannot create media directory: \(error.localizedDescription)")
        }

        var importedCount = 0
        let total = entries.count

        for (index, entry) in entries.enumerated() {
            let msg = "Downloading \(index + 1)/\(total): \(entry.name)"
            progressHandler?(msg)

            guard let ext = fileExtension(forMime: entry.mimeType) else {
                Log.project.warning("GDrive: skipping unsupported mime=\(entry.mimeType) file=\(entry.name)")
                continue
            }

            let filename = "gdrive-\(entry.id).\(ext)"
            let destURL = mediaDir.appendingPathComponent(filename)

            do {
                try await downloadFile(entry: entry, to: destURL)
            } catch {
                Log.project.error("GDrive: download failed for \(entry.name): \(error.localizedDescription)")
                progressHandler?("Failed: \(entry.name)")
                continue
            }

            // Register the asset in the editor.
            guard let asset = editor.addMediaAsset(from: destURL) else {
                Log.project.error("GDrive: failed to register asset for \(entry.name)")
                try? FileManager.default.removeItem(at: destURL)
                continue
            }

            // Set the display name from the Drive file name.
            let displayName = (entry.name as NSString).deletingPathExtension
            asset.name = displayName
            if let idx = editor.mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
                editor.mediaManifest.entries[idx].name = displayName
            }

            // Place in the specified media folder.
            if let folderId {
                editor.moveAssetsToFolder(assetIds: [asset.id], folderId: folderId)
            }

            importedCount += 1
            progressHandler?("Imported \(index + 1)/\(total): \(entry.name)")
        }

        Log.project.notice(
            "GDrive: import complete imported=\(importedCount)/\(total)"
        )
        return importedCount
    }
}
