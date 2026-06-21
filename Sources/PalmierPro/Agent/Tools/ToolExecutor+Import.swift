import Foundation

extension ToolExecutor {
    static let importDownloadMaxBytes: Int64 = 1024 * 1024 * 1024
    static let importBytesMaxBase64Length = 15 * 1024 * 1024
    static let importDownloadTimeout: TimeInterval = 120

    private static let importMediaAllowedKeys: Set<String> = ["source", "name", "folderId"]
    private static let importSourceAllowedKeys: Set<String> = ["url", "path", "bytes", "mimeType"]

    func importMedia(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.importMediaAllowedKeys, path: "import_media")
        guard let source = args["source"] as? [String: Any] else {
            throw ToolError("Missing required 'source' object")
        }
        try validateUnknownKeys(source, allowed: Self.importSourceAllowedKeys, path: "source")

        let urlStr = source.string("url")
        let pathStr = source.string("path")
        let bytesStr = source.string("bytes")
        let mimeType = source.string("mimeType")

        let setCount = [urlStr, pathStr, bytesStr].compactMap { $0 }.count
        guard setCount == 1 else {
            throw ToolError("source must set exactly one of 'url', 'path', or 'bytes' (got \(setCount))")
        }

        let folderId = try resolveFolderId(args, editor: editor)
        let providedName = args.string("name")

        if let pathStr {
            return try importFromPath(editor: editor, path: pathStr, name: providedName, folderId: folderId)
        }
        if let bytesStr {
            guard let mimeType else {
                throw ToolError("source.mimeType is required when source.bytes is set")
            }
            return try importFromBytes(editor: editor, base64: bytesStr, mimeType: mimeType, name: providedName, folderId: folderId)
        }
        if let urlStr {
            return try importFromURL(editor: editor, urlString: urlStr, mimeOverride: mimeType, name: providedName, folderId: folderId)
        }
        throw ToolError("unreachable")
    }

    private func importFromPath(editor: EditorViewModel, path: String, name: String?, folderId: String?) throws -> ToolResult {
        let fileURL = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
            throw ToolError("File not found: \(path)")
        }
        if isDir.boolValue {
            let summary = editor.importFinderItems([fileURL], into: folderId)
            guard summary.assetCount > 0 else {
                throw ToolError("No supported media found in folder: \(path)")
            }
            return .ok("Imported \(summary.assetCount) file(s) into \(summary.folderCount) folder(s) from '\(fileURL.lastPathComponent)', mirroring its structure. Available now in get_media / list_folders.")
        }
        let ext = fileURL.pathExtension.lowercased()
        guard ClipType(fileExtension: ext) != nil else {
            throw ToolError("Unsupported file extension '.\(ext)'. Supported: mov/mp4/m4v, mp3/wav/aac/m4a, png/jpg/jpeg/tiff/heic, json (Lottie).")
        }
        guard let asset = editor.addMediaAsset(from: fileURL) else {
            throw ToolError("Failed to import file: \(path)")
        }
        applyImportMetadata(editor: editor, asset: asset, name: name, folderId: folderId)
        return .ok("Imported '\(asset.name)' (id: \(asset.id), type: \(asset.type.rawValue)) from path. Available now in get_media.")
    }

    private func importFromBytes(editor: EditorViewModel, base64: String, mimeType: String, name: String?, folderId: String?) throws -> ToolResult {
        guard base64.utf8.count <= Self.importBytesMaxBase64Length else {
            throw ToolError("source.bytes is too large (\(base64.utf8.count) chars; max \(Self.importBytesMaxBase64Length)). Use source.url or source.path for larger files.")
        }
        guard let fileExt = Self.fileExtension(forMime: mimeType) else {
            throw ToolError("Unsupported mimeType '\(mimeType)'. Accepted: video/mp4, video/quicktime, audio/mpeg, audio/wav, audio/aac, audio/mp4, image/png, image/jpeg, image/tiff, image/heic.")
        }
        guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
            throw ToolError("source.bytes is not valid non-empty base64")
        }
        guard let projectURL = editor.projectURL else {
            throw ToolError("No project is open; cannot import bytes")
        }
        let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        } catch {
            throw ToolError("Failed to prepare media directory: \(error.localizedDescription)")
        }
        let filename = "imported-\(UUID().uuidString.prefix(8)).\(fileExt)"
        let destURL = mediaDir.appendingPathComponent(filename)
        do {
            try data.write(to: destURL)
        } catch {
            throw ToolError("Failed to write bytes to disk: \(error.localizedDescription)")
        }
        guard let asset = editor.addMediaAsset(from: destURL) else {
            try? FileManager.default.removeItem(at: destURL)
            throw ToolError("Failed to register imported asset")
        }
        applyImportMetadata(editor: editor, asset: asset, name: name, folderId: folderId)
        return .ok("Imported '\(asset.name)' (id: \(asset.id), type: \(asset.type.rawValue), \(data.count) bytes). Available now in get_media.")
    }

    private func importFromURL(editor: EditorViewModel, urlString: String, mimeOverride: String?, name: String?, folderId: String?) throws -> ToolResult {
        guard let url = URL(string: urlString) else {
            throw ToolError("source.url is not a valid URL")
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw ToolError("source.url must use https")
        }
        if url.user(percentEncoded: false) != nil || url.password(percentEncoded: false) != nil {
            throw ToolError("source.url must not embed credentials")
        }
        guard let host = url.host(percentEncoded: false), !host.isEmpty else {
            throw ToolError("source.url has no host")
        }

        let fileExt: String
        if let mimeOverride {
            guard let mapped = Self.fileExtension(forMime: mimeOverride) else {
                throw ToolError("Unsupported mimeType '\(mimeOverride)'. Accepted: video/mp4, video/quicktime, audio/mpeg, audio/wav, audio/aac, audio/mp4, image/png, image/jpeg, image/tiff, image/heic.")
            }
            fileExt = mapped
        } else {
            let urlExt = url.pathExtension.lowercased()
            guard !urlExt.isEmpty, ClipType(fileExtension: urlExt) != nil else {
                let shown = urlExt.isEmpty ? "(none)" : ".\(urlExt)"
                throw ToolError("Cannot infer media type from URL extension \(shown). Set source.mimeType to disambiguate (e.g. 'video/mp4', 'image/png').")
            }
            fileExt = urlExt
        }
        guard let type = ClipType(fileExtension: fileExt) else {
            throw ToolError("Unsupported file extension '.\(fileExt)'")
        }

        guard let projectURL = editor.projectURL else {
            throw ToolError("No project is open; cannot import from URL")
        }
        let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        } catch {
            throw ToolError("Failed to prepare media directory: \(error.localizedDescription)")
        }

        let id = UUID().uuidString
        let destURL = mediaDir.appendingPathComponent("imported-\(id.prefix(8)).\(fileExt)")

        let displayName: String
        if let name {
            displayName = name
        } else {
            let stem = url.deletingPathExtension().lastPathComponent
            displayName = stem.isEmpty ? "Imported asset" : stem
        }

        let placeholder = MediaAsset(id: id, url: destURL, type: type, name: displayName)
        placeholder.generationStatus = .downloading
        editor.mediaAssets.append(placeholder)
        if folderId != nil {
            applyImportMetadata(editor: editor, asset: placeholder, name: nil, folderId: folderId)
        }

        Task { @MainActor [weak editor] in
            guard let editor else { return }
            await Self.downloadImportedAsset(asset: placeholder, remoteURL: url, editor: editor)
        }

        return .ok("Import started. Placeholder asset id: \(id) (type: \(type.rawValue)). Status: downloading. Poll get_media — the asset appears once the download completes.")
    }

    @MainActor
    private static func downloadImportedAsset(asset: MediaAsset, remoteURL: URL, editor: EditorViewModel) async {
        do {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = importDownloadTimeout
            let delegate = ImportDownloadDelegate(maxBytes: importDownloadMaxBytes)
            let (tempURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)

            if let httpResp = response as? HTTPURLResponse, !(200..<300).contains(httpResp.statusCode) {
                try? FileManager.default.removeItem(at: tempURL)
                throw ToolError("server returned HTTP \(httpResp.statusCode)")
            }
            let downloadedSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            if downloadedSize > importDownloadMaxBytes {
                try? FileManager.default.removeItem(at: tempURL)
                throw ToolError("downloaded file exceeds max size (\(downloadedSize) > \(importDownloadMaxBytes) bytes)")
            }

            try? FileManager.default.removeItem(at: asset.url)
            try FileManager.default.moveItem(at: tempURL, to: asset.url)
            asset.generationStatus = .none
            editor.importMediaAsset(asset, skipAppend: true)
            await editor.finalizeImportedAsset(asset)
        } catch {
            let message = (error as? ToolError)?.message ?? error.localizedDescription
            Log.project.error("import_media download failed url=\(remoteURL.absoluteString) error=\(message)")
            asset.generationStatus = .failed(message)
        }
    }

    private func applyImportMetadata(editor: EditorViewModel, asset: MediaAsset, name: String?, folderId: String?) {
        if let name {
            asset.name = name
            if let idx = editor.mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
                editor.mediaManifest.entries[idx].name = name
            }
        }
        if let folderId {
            editor.moveAssetsToFolder(assetIds: [asset.id], folderId: folderId)
        }
    }

    private static func fileExtension(forMime mime: String) -> String? {
        switch mime.lowercased() {
        case "video/mp4", "video/mpeg4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aac": return "aac"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/tiff": return "tiff"
        case "image/heic", "image/heif": return "heic"
        case "application/json", "application/vnd.lottie+json": return "json"
        default: return nil
        }
    }
}

/// Caps the in-flight download size by cancelling the task once the byte threshold is crossed.
/// `download(for:delegate:)` still finalizes the temp file on success.
fileprivate final class ImportDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maxBytes: Int64
    init(maxBytes: Int64) { self.maxBytes = maxBytes }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesExpectedToWrite > 0 && totalBytesExpectedToWrite > maxBytes {
            downloadTask.cancel()
            return
        }
        if totalBytesWritten > maxBytes {
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // No-op: the async download(for:delegate:) API copies the temp file for us.
    }
}
