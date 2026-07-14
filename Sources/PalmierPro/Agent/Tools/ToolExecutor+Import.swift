import Foundation

extension ToolExecutor {
    nonisolated static let remoteImportMaxBytes: Int64 = 5 * 1024 * 1024 * 1024
    nonisolated static let importBytesMaxBase64Length = 15 * 1024 * 1024
    nonisolated static let remoteImportRequestTimeout: TimeInterval = 15 * 60

    private static let importMediaAllowedKeys: Set<String> = ["source", "name", "folder"]
    private static let importSourceAllowedKeys: Set<String> = ["url", "path", "bytes", "matte", "mimeType"]
    private nonisolated static let acceptedMimeTypesMessage = "Accepted: video/mp4, video/quicktime, audio/mpeg, audio/wav, audio/aac, audio/mp4, audio/aiff, audio/flac, image/png, image/jpeg, image/tiff, image/heic."

    private struct ImportPathStatus: Sendable {
        let exists: Bool
        let isDirectory: Bool
    }

    private struct ImportedBytesFile: Sendable {
        let url: URL
        let byteCount: Int
    }

    func importMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.importMediaAllowedKeys, path: "import_media")
        guard let source = args["source"] as? [String: Any] else {
            throw ToolError("Missing required 'source' object")
        }
        try validateUnknownKeys(source, allowed: Self.importSourceAllowedKeys, path: "source")

        let urlStr = source.string("url")
        let pathStr = source.string("path")
        let bytesStr = source.string("bytes")
        let matte = source["matte"] as? [String: Any]
        let mimeType = source.string("mimeType")

        let setCount = [urlStr, pathStr, bytesStr].compactMap { $0 }.count + (matte == nil ? 0 : 1)
        guard setCount == 1 else {
            throw ToolError("source must set exactly one of 'url', 'path', 'bytes', or 'matte' (got \(setCount))")
        }

        let folderId = try resolveFolder(args, editor: editor)
        let providedName = args.string("name")

        if let pathStr {
            return try await importFromPath(editor: editor, path: pathStr, name: providedName, folderId: folderId)
        }
        if let bytesStr {
            guard let mimeType else {
                throw ToolError("source.mimeType is required when source.bytes is set")
            }
            return try await importFromBytes(editor: editor, base64: bytesStr, mimeType: mimeType, name: providedName, folderId: folderId)
        }
        if let matte {
            return try await importMatte(editor: editor, matte: matte, name: providedName, folderId: folderId)
        }
        if let urlStr {
            return try importFromURL(editor: editor, urlString: urlStr, mimeOverride: mimeType, name: providedName, folderId: folderId)
        }
        throw ToolError("unreachable")
    }

    private func importFromPath(editor: EditorViewModel, path: String, name: String?, folderId: String?) async throws -> ToolResult {
        let fileURL = URL(fileURLWithPath: path)
        let status = await Task.detached(priority: .utility) {
            Self.importPathStatus(for: fileURL)
        }.value
        guard status.exists else {
            throw ToolError("File not found: \(path)")
        }
        if status.isDirectory {
            let summary = await editor.importFinderItems([fileURL], into: folderId)
            guard summary.assetCount > 0 else {
                throw ToolError("No supported media found in folder: \(path)")
            }
            return .ok(Self.jsonString([
                "status": "ready",
                "imported": summary.assetCount,
                "folders": summary.folderCount,
                "note": "Imported from '\(fileURL.lastPathComponent)', mirroring its structure. See get_media.",
            ] as [String: Any]) ?? "{}")
        }
        let ext = fileURL.pathExtension.lowercased()
        guard let type = ClipType(fileExtension: ext) else {
            throw ToolError("Unsupported file extension '.\(ext)'. Supported: mov/mp4/m4v, mp3/wav/aac/m4a/aiff/aifc/flac, png/jpg/jpeg/tiff/heic, json (Lottie).")
        }
        if type == .lottie, !LottieVideoGenerator.isLottie(at: fileURL) {
            throw ToolError("Unsupported Lottie file: \(fileURL.lastPathComponent)")
        }
        guard let projectURL = editor.projectURL else {
            throw ToolError("No project is open; cannot import from path")
        }

        let displayName = name ?? fileURL.deletingPathExtension().lastPathComponent
        let placeholder = createImportPlaceholder(
            editor: editor,
            projectURL: projectURL,
            type: type,
            fileExtension: ext,
            displayName: displayName,
            folderId: folderId,
            importInput: MediaImportInput(sourcePath: fileURL.path, createdAt: Date())
        )

        Task { @MainActor [weak editor] in
            guard let editor else { return }
            await Self.copyImportedAsset(asset: placeholder, sourceURL: fileURL, editor: editor)
        }

        return .ok(Self.jsonString([
            "mediaRef": placeholder.id,
            "type": type.rawValue,
            "status": "downloading",
            "note": "Copying in the background. Poll get_media with ids:[\"\(placeholder.id)\"] until generationStatus clears.",
        ]) ?? "{}")
    }

    private func importFromBytes(editor: EditorViewModel, base64: String, mimeType: String, name: String?, folderId: String?) async throws -> ToolResult {
        guard base64.utf8.count <= Self.importBytesMaxBase64Length else {
            throw ToolError("source.bytes is too large (\(base64.utf8.count) chars; max \(Self.importBytesMaxBase64Length)). Use source.url or source.path for larger files.")
        }
        guard let projectURL = editor.projectURL else {
            throw ToolError("No project is open; cannot import bytes")
        }
        let imported = try await Task.detached(priority: .userInitiated) {
            try Self.writeImportedBytes(base64: base64, mimeType: mimeType, projectURL: projectURL)
        }.value
        guard let asset = editor.addMediaAsset(from: imported.url) else {
            try? await Task.detached(priority: .utility) {
                try FileManager.default.removeItem(at: imported.url)
            }.value
            throw ToolError("Failed to register imported asset")
        }
        applyImportMetadata(editor: editor, asset: asset, name: name, folderId: folderId)
        return .ok(Self.jsonString([
            "mediaRef": asset.id,
            "name": asset.name,
            "type": asset.type.rawValue,
            "status": "ready",
        ]) ?? "{}")
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
                throw ToolError("Unsupported mimeType '\(mimeOverride)'. \(Self.acceptedMimeTypesMessage)")
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

        let displayName: String
        if let name {
            displayName = name
        } else {
            let stem = url.deletingPathExtension().lastPathComponent
            displayName = stem.isEmpty ? "Imported asset" : stem
        }

        let placeholder = createImportPlaceholder(
            editor: editor,
            projectURL: projectURL,
            type: type,
            fileExtension: fileExt,
            displayName: displayName,
            folderId: folderId,
            importInput: MediaImportInput(sourceURL: url.absoluteString, createdAt: Date())
        )

        Task { @MainActor [weak editor] in
            guard let editor else { return }
            await Self.downloadImportedAsset(asset: placeholder, remoteURL: url, editor: editor)
        }

        return .ok(Self.jsonString([
            "mediaRef": placeholder.id,
            "type": type.rawValue,
            "status": "downloading",
            "note": "Downloading in the background. Poll get_media with ids:[\"\(placeholder.id)\"] until generationStatus clears.",
        ]) ?? "{}")
    }

    private func createImportPlaceholder(
        editor: EditorViewModel,
        projectURL: URL,
        type: ClipType,
        fileExtension: String,
        displayName: String,
        folderId: String?,
        importInput: MediaImportInput
    ) -> MediaAsset {
        let id = UUID().uuidString
        let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        let destURL = mediaDir.appendingPathComponent("imported-\(id.prefix(8)).\(fileExtension)")
        let placeholder = MediaAsset(id: id, url: destURL, type: type, name: displayName)
        placeholder.folderId = folderId
        placeholder.importInput = importInput
        placeholder.generationStatus = .downloading
        editor.importMediaAsset(placeholder)
        editor.onProjectCheckpointRequired?()
        return placeholder
    }

    @MainActor
    private static func downloadImportedAsset(asset: MediaAsset, remoteURL: URL, editor: EditorViewModel) async {
        do {
            var request = URLRequest(url: remoteURL)
            request.timeoutInterval = remoteImportRequestTimeout
            let delegate = ImportDownloadDelegate(maxBytes: remoteImportMaxBytes)
            let (tempURL, response) = try await URLSession.shared.download(for: request, delegate: delegate)

            if let httpResp = response as? HTTPURLResponse, !(200..<300).contains(httpResp.statusCode) {
                await Task.detached(priority: .utility) {
                    try? FileManager.default.removeItem(at: tempURL)
                }.value
                throw ToolError("server returned HTTP \(httpResp.statusCode)")
            }

            let destinationURL = asset.url
            _ = try await Task.detached(priority: .userInitiated) {
                try FileIO.moveReplacingDestination(
                    from: tempURL,
                    to: destinationURL,
                    maxBytes: remoteImportMaxBytes
                )
            }.value
            await finishImportedAsset(asset, editor: editor)
        } catch {
            let message = (error as? ToolError)?.message ?? error.localizedDescription
            Log.project.error("import_media download failed url=\(remoteURL.absoluteString) error=\(message)")
            failImportedAsset(asset, editor: editor, message: message)
        }
    }

    @MainActor
    private static func copyImportedAsset(asset: MediaAsset, sourceURL: URL, editor: EditorViewModel) async {
        do {
            let destinationURL = asset.url
            _ = try await Task.detached(priority: .userInitiated) {
                try FileIO.copyReplacingDestination(
                    from: sourceURL,
                    to: destinationURL
                )
            }.value
            await finishImportedAsset(asset, editor: editor)
        } catch {
            let message = (error as? ToolError)?.message ?? error.localizedDescription
            Log.project.error("import_media copy failed path=\(sourceURL.path) error=\(message)")
            failImportedAsset(asset, editor: editor, message: message)
        }
    }

    @MainActor
    private static func finishImportedAsset(_ asset: MediaAsset, editor: EditorViewModel) async {
        let finalized = await editor.finalizeImportedAsset(asset)
        guard finalized else {
            editor.onProjectCheckpointRequired?()
            return
        }
        asset.importInput = nil
        editor.updateManifestMetadata(for: [asset])
        editor.onProjectCheckpointRequired?()
    }

    @MainActor
    private static func failImportedAsset(_ asset: MediaAsset, editor: EditorViewModel, message: String) {
        asset.generationStatus = .failed(message)
        editor.updateManifestMetadata(for: [asset])
        editor.onProjectCheckpointRequired?()
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

    private nonisolated static func importPathStatus(for url: URL) -> ImportPathStatus {
        var isDirectory = ObjCBool(false)
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        return ImportPathStatus(exists: exists, isDirectory: isDirectory.boolValue)
    }

    private nonisolated static func writeImportedBytes(base64: String, mimeType: String, projectURL: URL) throws -> ImportedBytesFile {
        guard let fileExt = fileExtension(forMime: mimeType) else {
            throw ToolError("Unsupported mimeType '\(mimeType)'. \(acceptedMimeTypesMessage)")
        }
        guard let data = Data(base64Encoded: base64, options: [.ignoreUnknownCharacters]), !data.isEmpty else {
            throw ToolError("source.bytes is not valid non-empty base64")
        }
        let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        let filename = "imported-\(UUID().uuidString.prefix(8)).\(fileExt)"
        let destURL = mediaDir.appendingPathComponent(filename)
        do {
            try FileIO.writeData(data, to: destURL)
        } catch {
            throw ToolError("Failed to write bytes to disk: \(error.localizedDescription)")
        }
        return ImportedBytesFile(url: destURL, byteCount: data.count)
    }

    private nonisolated static func fileExtension(forMime mime: String) -> String? {
        switch mime.lowercased() {
        case "video/mp4", "video/mpeg4": return "mp4"
        case "video/quicktime": return "mov"
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/wav", "audio/x-wav", "audio/wave": return "wav"
        case "audio/aac": return "aac"
        case "audio/mp4", "audio/m4a", "audio/x-m4a": return "m4a"
        case "audio/aiff", "audio/x-aiff": return "aiff"
        case "audio/aifc", "audio/x-aifc": return "aifc"
        case "audio/flac", "audio/x-flac": return "flac"
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/tiff": return "tiff"
        case "image/heic", "image/heif": return "heic"
        case "application/json", "application/vnd.lottie+json": return "json"
        default: return nil
        }
    }

    private func importMatte(
        editor: EditorViewModel, matte: [String: Any], name: String?, folderId: String?
    ) async throws -> ToolResult {
        try validateUnknownKeys(matte, allowed: ["hex", "aspectRatio"], path: "source.matte")
        guard let hex = matte.string("hex")?.trimmingCharacters(in: .whitespacesAndNewlines), !hex.isEmpty
        else { throw ToolError("source.matte requires 'hex'.") }
        let aspect: MatteAspect
        if let raw = matte.string("aspectRatio") {
            guard let parsed = MatteAspect.parse(raw) else {
                throw ToolError("source.matte: unknown aspectRatio '\(raw)'. Use one of \(MatteAspect.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            aspect = parsed
        } else {
            aspect = .project
        }
        let asset = try await editor.createMatte(hex: hex, aspect: aspect, folderId: folderId, name: name)
        return .ok(Self.jsonString([
            "mediaRef": asset.id,
            "name": asset.name,
            "type": asset.type.rawValue,
            "status": "ready",
        ]) ?? "{}")
    }
}

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
