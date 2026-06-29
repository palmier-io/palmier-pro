import Foundation
@preconcurrency import Combine

/// Used by replace-clip callbacks so only the
/// first successful asset of an N-image generation swaps the clip
@MainActor
final class FirstOnlyFlag {
    private var fired = false
    func fire() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}

@MainActor
final class GenerationService {

    private static let uploadCacheTTL: TimeInterval = 6 * 24 * 60 * 60
    private var resumedBackendJobIds: Set<String> = []

    private struct PreparedReferences {
        let uploaded: [String]
        let tempFiles: [URL]
    }

    @discardableResult
    func generate(
        genInput: GenerationInput,
        assetType: ClipType,
        placeholderDuration: Double,
        references: [MediaAsset] = [],
        trimmedSourceOverride: TrimmedSource? = nil,
        preUploadedURLs: [String]? = nil,
        name: String? = nil,
        numImages: Int = 1,
        folderId: String? = nil,
        buildParams: @escaping ([String]) -> BackendGenerationParams,
        snapshotRefs: (@Sendable (inout GenerationInput, [String]) -> Void)? = nil,
        preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)? = nil,
        fileExtension: String,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        let count = max(1, min(4, numImages))
        let baseName = name ?? String(genInput.prompt.prefix(30))

        let resolvedFolderId = folderId.flatMap { id in
            editor.folder(id: id) != nil ? id : nil
        }
        var placeholders: [MediaAsset] = []
        let destDir = Self.destinationDirectory(for: projectURL)

        for outputIndex in 0..<count {
            var placeholderInput = genInput
            placeholderInput.outputIndex = outputIndex
            let placeholder = createPlaceholder(
                type: assetType,
                name: baseName,
                duration: placeholderDuration,
                genInput: placeholderInput,
                folderId: resolvedFolderId,
                destDir: destDir,
                fileExtension: fileExtension,
                editor: editor
            )
            placeholders.append(placeholder)
        }
        let primaryId = placeholders[0].id

        Task { @MainActor in
            do {
                let prepared = try await self.prepareReferences(
                    references: references,
                    trimmedSourceOverride: trimmedSourceOverride,
                    preUploadedURLs: preUploadedURLs,
                    preprocessRef: preprocessRef
                )
                defer { Self.cleanupTempFiles(prepared.tempFiles) }
                let uploaded = prepared.uploaded

                var finalGenInput = genInput
                if let snapshotRefs {
                    snapshotRefs(&finalGenInput, uploaded)
                } else {
                    finalGenInput.imageURLs = uploaded.isEmpty ? nil : uploaded
                }
                if finalGenInput.createdAt == nil {
                    finalGenInput.createdAt = Date()
                }
                for (outputIndex, placeholder) in placeholders.enumerated() {
                    var storedInput = finalGenInput
                    storedInput.outputIndex = outputIndex
                    updateGenerationMetadata(placeholder, editor: editor) { input in
                        input = storedInput
                    }
                }

                let params = buildParams(uploaded)

                await self.runJob(
                    placeholders: placeholders,
                    params: params,
                    genInput: finalGenInput,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            } catch {
                let message = error.localizedDescription
                Log.generation.error("upload failed model=\(genInput.model) error=\(message)")
                for placeholder in placeholders {
                    updateGenerationMetadata(placeholder, editor: editor, status: .failed("Upload failed: \(message)"))
                }
                onFailure?()
            }
        }

        return primaryId
    }

    private func prepareReferences(
        references: [MediaAsset],
        trimmedSourceOverride: TrimmedSource?,
        preUploadedURLs: [String]?,
        preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)?
    ) async throws -> PreparedReferences {
        if let preUploadedURLs, !preUploadedURLs.isEmpty {
            return PreparedReferences(uploaded: preUploadedURLs, tempFiles: [])
        }

        var tempFiles: [URL] = []
        do {
            var urlsToUpload = references.map(\.url)
            let refTypes = references.map(\.type)
            if let trim = trimmedSourceOverride, trim.hasTrim, !urlsToUpload.isEmpty {
                Log.generation.notice("using trimmed source: frames \(trim.trimStartFrame)+\(trim.sourceFramesConsumed) of \(urlsToUpload[0].lastPathComponent)")
                let extracted = try await VideoTrimExtractor.extract(trim)
                urlsToUpload[0] = extracted
                tempFiles.append(extracted)
            }
            if let preprocessRef, !references.isEmpty {
                let rewrites = try await preprocessedReferenceURLs(references: references, preprocessRef: preprocessRef)
                for (i, rewritten) in rewrites {
                    guard let rewritten else { continue }
                    urlsToUpload[i] = rewritten
                    tempFiles.append(rewritten)
                }
            }
            let uploaded = try await uploadReferences(
                at: urlsToUpload,
                types: refTypes,
                cacheKeys: uploadCacheKeys(
                    references: references,
                    trimmedFirstReference: trimmedSourceOverride?.hasTrim == true,
                    hasPreprocess: preprocessRef != nil
                ),
            )
            return PreparedReferences(uploaded: uploaded, tempFiles: tempFiles)
        } catch {
            Self.cleanupTempFiles(tempFiles)
            throw error
        }
    }

    private func preprocessedReferenceURLs(
        references: [MediaAsset],
        preprocessRef: @escaping @Sendable (Int, MediaAsset) async throws -> URL?
    ) async throws -> [(Int, URL?)] {
        try await withThrowingTaskGroup(of: (Int, URL?).self) { group in
            for (i, asset) in references.enumerated() {
                group.addTask { (i, try await preprocessRef(i, asset)) }
            }
            var results: [(Int, URL?)] = []
            for try await result in group { results.append(result) }
            return results
        }
    }

    private func uploadCacheKeys(
        references: [MediaAsset],
        trimmedFirstReference: Bool,
        hasPreprocess: Bool
    ) -> [MediaAsset?] {
        references.enumerated().map { index, asset in
            if hasPreprocess { return nil }
            if index == 0 && trimmedFirstReference { return nil }
            return asset
        }
    }

    private static func cleanupTempFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Shared

    private func createPlaceholder(
        type: ClipType,
        name: String,
        duration: Double,
        genInput: GenerationInput,
        folderId: String?,
        destDir: URL,
        fileExtension: String,
        editor: EditorViewModel
    ) -> MediaAsset {
        let id = UUID().uuidString
        let destURL = destDir.appendingPathComponent("gen-\(id.prefix(8)).\(fileExtension)")
        let placeholder = MediaAsset(
            id: id,
            url: destURL,
            type: type,
            name: name,
            duration: duration,
            generationInput: genInput
        )
        placeholder.generationStatus = .preparing
        placeholder.folderId = folderId
        editor.importMediaAsset(placeholder)
        return placeholder
    }

    private static func destinationDirectory(for projectURL: URL?) -> URL {
        if let projectURL {
            return projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
    }

    @discardableResult
    private func downloadAndFinalize(asset: MediaAsset, remoteURL: URL, editor: EditorViewModel) async -> Bool {
        if asset.generationStatus != .downloading {
            updateGenerationMetadata(asset, editor: editor, status: .downloading)
        }
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
            let realExt = remoteURL.pathExtension.lowercased()
            if !realExt.isEmpty, realExt != asset.url.pathExtension.lowercased(),
               ClipType(fileExtension: realExt) != nil {
                asset.url = asset.url.deletingPathExtension().appendingPathExtension(realExt)
            }
            let destinationURL = asset.url
            try await Task.detached(priority: .utility) {
                _ = try FileIO.moveReplacingDestination(from: tempURL, to: destinationURL)
            }.value

            asset.pendingDownloadURL = nil
            asset.generationStatus = .none
            editor.importMediaAsset(asset, skipAppend: true)
            editor.appendGenerationLog(for: asset)
            await editor.finalizeImportedAsset(asset)
            return true
        } catch {
            let message = error.localizedDescription
            Log.generation.error("download failed url=\(remoteURL.absoluteString) error=\(message)")
            asset.pendingDownloadURL = remoteURL
            updateGenerationMetadata(asset, editor: editor, status: .failed(message))
            return false
        }
    }

    func retryDownload(asset: MediaAsset, editor: EditorViewModel) {
        guard let remoteURL = asset.pendingDownloadURL else { return }
        Task { @MainActor in
            await downloadAndFinalize(asset: asset, remoteURL: remoteURL, editor: editor)
        }
    }

    func resumePendingGenerations(editor: EditorViewModel) {
        func sorted(_ assets: [MediaAsset]) -> [MediaAsset] {
            assets.sorted {
                let left = $0.generationInput?.outputIndex ?? 0
                let right = $1.generationInput?.outputIndex ?? 0
                return left < right
            }
        }

        let pending = editor.mediaAssets.filter(\.isRecoveringGeneration)

        let byBackendJob = Dictionary(grouping: pending.compactMap { asset -> (String, MediaAsset)? in
            guard let backendJobId = asset.generationInput?.backendJobId, !backendJobId.isEmpty else { return nil }
            return (backendJobId, asset)
        }, by: { $0.0 })

        for (backendJobId, group) in byBackendJob where !resumedBackendJobIds.contains(backendJobId) {
            let placeholders = sorted(group.map { $0.1 })
            resumedBackendJobIds.insert(backendJobId)
            Task { @MainActor [weak self, weak editor] in
                guard let self, let editor else { return }
                await self.monitorBackendJob(
                    backendJobId: backendJobId,
                    placeholders: placeholders,
                    editor: editor,
                    onComplete: nil,
                    onFailure: nil
                )
                self.resumedBackendJobIds.remove(backendJobId)
            }
        }
    }

    private func updateGenerationMetadata(
        _ asset: MediaAsset,
        editor: EditorViewModel,
        status: MediaAsset.GenerationStatus? = nil,
        mutateInput: ((inout GenerationInput) -> Void)? = nil
    ) {
        if let status {
            asset.generationStatus = status
        }
        if let mutateInput, var input = asset.generationInput {
            mutateInput(&input)
            asset.generationInput = input
        }
        editor.updateManifestMetadata(for: asset)
    }

    /// Uploads each reference and returns the hosted URLs.
    private func uploadReferences(
        at urls: [URL],
        types: [ClipType],
        cacheKeys: [MediaAsset?],
    ) async throws -> [String] {
        guard !urls.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, url) in urls.enumerated() {
                let type = types.indices.contains(i) ? types[i] : .image
                let cacheKey = cacheKeys.indices.contains(i) ? cacheKeys[i] : nil
                if let cacheKey, let hit = cacheKey.freshRemoteURL {
                    group.addTask { (i, hit) }
                    continue
                }
                let contentType = Self.contentType(for: url, fallback: type)
                group.addTask {
                    let uploaded = try await GenerationBackend.uploadReference(
                        fileURL: url,
                        contentType: contentType,
                    )
                    if let cacheKey {
                        await Self.recordUploadCache(asset: cacheKey, url: uploaded)
                    }
                    return (i, uploaded)
                }
            }
            var results = [(Int, String)]()
            for try await r in group { results.append(r) }
            return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    @MainActor
    private static func recordUploadCache(asset: MediaAsset, url: String) {
        asset.cachedRemoteURL = url
        asset.cachedRemoteURLExpiresAt = Date().addingTimeInterval(uploadCacheTTL)
    }

    private static func contentType(for url: URL, fallback: ClipType) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "aiff", "aif", "aifc": return "audio/aiff"
        case "flac": return "audio/flac"
        default:
            switch fallback {
            case .image: return "image/jpeg"
            case .video: return "video/mp4"
            case .audio: return "audio/mpeg"
            case .text: return "application/octet-stream"
            case .lottie: return "application/json"
            }
        }
    }

    // MARK: - Job execution

    private func runJob(
        placeholders: [MediaAsset],
        params: BackendGenerationParams,
        genInput: GenerationInput,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        let runId = String(UUID().uuidString.prefix(8))
        Log.generation.notice("run \(runId) start model=\(genInput.model) placeholders=\(placeholders.count)")
        defer { Log.generation.notice("run \(runId) settled") }

        let jobId: String
        do {
            jobId = try await GenerationBackend.submit(
                model: genInput.model,
                params: params,
                projectId: editor.projectId,
            )
        } catch {
            let message = error.localizedDescription
            Log.generation.error("submit failed model=\(genInput.model) error=\(message)")
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(message))
            }
            onFailure?()
            return
        }

        for placeholder in placeholders {
            updateGenerationMetadata(placeholder, editor: editor, status: .generating) { input in
                input.backendJobId = jobId
            }
        }
        editor.onProjectCheckpointRequired?()

        await monitorBackendJob(
            backendJobId: jobId,
            placeholders: placeholders,
            editor: editor,
            failIfUnavailable: true,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    private func monitorBackendJob(
        backendJobId: String,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        failIfUnavailable: Bool = false,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard let publisher = GenerationBackend.subscribe(jobId: backendJobId) else {
            if failIfUnavailable {
                for placeholder in placeholders {
                    updateGenerationMetadata(placeholder, editor: editor, status: .failed("Backend not configured"))
                }
                editor.onProjectCheckpointRequired?()
                onFailure?()
            }
            return
        }

        for await jobOpt in backendJobStream(from: publisher) {
            guard let job = jobOpt else { continue }
            if await applyBackendJobUpdate(
                job: job,
                backendJobId: backendJobId,
                placeholders: placeholders,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            ) {
                return
            }
        }

        // Stream ended without a terminal update: finish from persisted URLs, else retry on reopen.
        let persisted = placeholders.compactMap(\.generationInput?.resultURLs).first ?? []
        guard !persisted.isEmpty else { return }
        await finalizeSuccess(
            urlStrings: persisted,
            placeholders: placeholders,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    private func backendJobStream<Failure: Error>(
        from publisher: AnyPublisher<BackendGenerationJob?, Failure>
    ) -> AsyncStream<BackendGenerationJob?> {
        AsyncStream<BackendGenerationJob?> { continuation in
            let cancellable = publisher
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { _ in continuation.finish() },
                    receiveValue: { value in continuation.yield(value) },
                )
            continuation.onTermination = { _ in cancellable.cancel() }
        }
    }

    private func applyBackendJobUpdate(
        job: BackendGenerationJob,
        backendJobId: String,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async -> Bool {
        switch job.status {
        case .succeeded:
            if updateBackendJobMetadata(
                placeholders,
                backendJobId: backendJobId,
                editor: editor
            ) {
                editor.onProjectCheckpointRequired?()
            }
            await finalizeSuccess(
                urlStrings: job.resultUrls ?? [],
                placeholders: placeholders,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure,
            )
            return true
        case .failed:
            let message = job.errorMessage ?? "Generation failed"
            Log.generation.error("job \(backendJobId) failed: \(message)")
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(message)) { input in
                    input.backendJobId = backendJobId
                }
            }
            editor.onProjectCheckpointRequired?()
            onFailure?()
            return true
        case .queued, .running:
            if updateBackendJobMetadata(
                placeholders,
                backendJobId: backendJobId,
                editor: editor
            ) {
                editor.onProjectCheckpointRequired?()
            }
            return false
        }
    }

    @discardableResult
    private func updateBackendJobMetadata(
        _ placeholders: [MediaAsset],
        backendJobId: String,
        editor: EditorViewModel
    ) -> Bool {
        var changed = false
        for placeholder in placeholders {
            guard placeholder.generationStatus != .downloading,
                    placeholder.generationStatus != .generating ||
                    placeholder.generationInput?.backendJobId != backendJobId else {
                continue
            }
            updateGenerationMetadata(placeholder, editor: editor, status: .generating) { input in
                input.backendJobId = backendJobId
            }
            changed = true
        }
        return changed
    }

    private func finalizeSuccess(
        urlStrings: [String],
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard !urlStrings.isEmpty else {
            Log.generation.error("backend job succeeded with no resultUrls")
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed("No URL in response"))
            }
            onFailure?()
            return
        }
        if urlStrings.count < placeholders.count {
            Log.generation.notice("backend returned \(urlStrings.count) URL(s) for \(placeholders.count) placeholder(s); marking extras as failed")
        }

        var finalized: [MediaAsset] = []
        for (i, placeholder) in placeholders.enumerated() {
            let outputIndex = placeholder.generationInput?.outputIndex ?? i
            guard outputIndex < urlStrings.count, let remote = URL(string: urlStrings[outputIndex]) else {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed("No URL for placeholder"))
                continue
            }
            updateGenerationMetadata(placeholder, editor: editor, status: .downloading) { input in
                input.resultURLs = urlStrings
            }
            if await downloadAndFinalize(asset: placeholder, remoteURL: remote, editor: editor) {
                onComplete?(placeholder)
                finalized.append(placeholder)
            }
        }

        if let first = finalized.first {
            AppNotifications.generationComplete(
                assetId: first.id,
                projectURL: editor.projectURL,
                assetName: first.name,
                assetType: first.type,
                count: finalized.count
            )
        } else {
            onFailure?()
        }
    }

}
