import Foundation
@preconcurrency import Combine
@preconcurrency import ConvexMobile

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

    enum StartError: String, LocalizedError {
        case projectUnavailable = "generation_project_unavailable"
        case suspended = "generation_suspended"
        case canceled = "generation_canceled"
        case invalidDraft = "generation_invalid_draft"
        case preparationChanged = "generation_preparation_changed"

        var errorDescription: String? { rawValue }

        @MainActor var localizedMessage: String {
            switch self {
            case .projectUnavailable: L10n.string("Generation is unavailable while the project is closing.")
            case .suspended: L10n.string("Generation is paused. Reopen the project to resume.")
            case .canceled: L10n.string("Generation canceled.")
            case .invalidDraft: L10n.string("Select a completed draft to enhance.")
            case .preparationChanged: L10n.string("Generation inputs changed. Submit again.")
            }
        }
    }

    static func localizedFailureMessage(_ message: String) -> String {
        StartError(rawValue: message)?.localizedMessage ?? L10n.string(key: message)
    }

    private static let uploadCacheTTL: TimeInterval = 6 * 24 * 60 * 60
    private var resumedBackendJobIds: Set<String> = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var downloadAttempts: [String: UUID] = [:]
    private var isSuspending = false
    private var suspensionWaiterCount = 0
    private let beforeTaskStart: @MainActor () async -> Void
    private let submitGeneration: @MainActor (String, BackendGenerationParams, String?) async throws -> String
    private let subscribe: @MainActor (String) -> AnyPublisher<BackendGenerationJob?, ClientError>?
    private let downloadMedia: @Sendable (URL) async throws -> DownloadedMedia

    struct DownloadedMedia: Sendable {
        let fileURL: URL
        let httpStatusCode: Int?
    }

    init(
        beforeTaskStart: @escaping @MainActor () async -> Void = {},
        submitGeneration: @escaping @MainActor (String, BackendGenerationParams, String?) async throws -> String = {
            try await GenerationBackend.submit(model: $0, params: $1, projectId: $2)
        },
        subscribe: @escaping @MainActor (String) -> AnyPublisher<BackendGenerationJob?, ClientError>? = {
            GenerationBackend.subscribe(jobId: $0)
        },
        downloadMedia: @escaping @Sendable (URL) async throws -> DownloadedMedia = {
            let (fileURL, response) = try await URLSession.shared.download(from: $0)
            return DownloadedMedia(fileURL: fileURL, httpStatusCode: (response as? HTTPURLResponse)?.statusCode)
        }
    ) {
        self.beforeTaskStart = beforeTaskStart
        self.submitGeneration = submitGeneration
        self.subscribe = subscribe
        self.downloadMedia = downloadMedia
    }

    func requireAvailable(editor: EditorViewModel) throws {
        guard !Task.isCancelled else { throw StartError.canceled }
        guard !editor.projectPackageCoordinator.isClosing, !editor.projectPackageCoordinator.isClosed else {
            throw StartError.projectUnavailable
        }
        guard !isSuspending else { throw StartError.suspended }
    }

    private func launch(
        onCancellation: @escaping @MainActor () -> Void,
        onFinish: @escaping @MainActor () -> Void = {},
        operation: @escaping @MainActor () async -> Void
    ) {
        let id = UUID()
        tasks[id] = Task { @MainActor in
            defer {
                if Task.isCancelled { onCancellation() }
                onFinish()
                tasks.removeValue(forKey: id)
            }
            await beforeTaskStart()
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    func suspendAndWait() async {
        isSuspending = true
        suspensionWaiterCount += 1
        defer { suspensionWaiterCount -= 1 }
        let running = Array(tasks.values)
        running.forEach { $0.cancel() }
        for task in running { await task.value }
    }

    @discardableResult
    private func cancelPlaceholders(
        _ placeholders: [MediaAsset], editor: EditorViewModel, backendJobId: String? = nil,
        onFailure: (@MainActor () -> Void)?
    ) -> Bool {
        var changed = false
        for asset in placeholders where editor.mediaAssetsById[asset.id] === asset && asset.isGenerating {
            if let backendJobId, asset.generationInput?.backendJobId != backendJobId { continue }
            updateGenerationMetadata(asset, editor: editor, status: .failed(L10n.key("Generation canceled.")))
            changed = true
        }
        if changed {
            editor.onProjectCheckpointRequired?()
            onFailure?()
        }
        return changed
    }

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
        preprocessRef: (@Sendable (Int, MediaAsset, URL) async throws -> URL?)? = nil,
        preprocessSourceVideo: (@Sendable (URL) async throws -> URL?)? = nil,
        fileExtension: String,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) throws -> String {
        try requireAvailable(editor: editor)
        let projectId = editor.projectId
        let referenceURLs = references.map(\.url)
        let referencesAreCurrent: @MainActor () -> Bool = {
            zip(references, referenceURLs).allSatisfy { asset, url in
                editor.mediaAssetsById[asset.id] === asset && asset.url == url
            }
        }
        guard referencesAreCurrent() else { throw StartError.preparationChanged }
        let failureFlag = FirstOnlyFlag()
        let fail: @MainActor () -> Void = { if failureFlag.fire() { onFailure?() } }
        var completedAnyOutput = false
        let complete: @MainActor (MediaAsset) -> Void = {
            completedAnyOutput = true
            onComplete?($0)
        }
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
        captureSubmission(genInput: genInput, assetType: assetType, outputCount: count, editor: editor)

        launch(onCancellation: {
            if !self.cancelPlaceholders(placeholders, editor: editor, onFailure: fail), !completedAnyOutput { fail() }
        }) {
            do {
                guard referencesAreCurrent() else { throw StartError.preparationChanged }
                let prepared = try await self.prepareReferences(
                    references: references,
                    trimmedSourceOverride: trimmedSourceOverride,
                    preUploadedURLs: preUploadedURLs,
                    preprocessRef: preprocessRef,
                    preprocessSourceVideo: preprocessSourceVideo
                )
                try await Self.cleanupTempFiles(prepared.tempFiles)
                try Task.checkCancellation()
                guard editor.projectId == projectId,
                      referencesAreCurrent(),
                      placeholders.contains(where: { editor.mediaAssetsById[$0.id] === $0 }) else {
                    throw StartError.preparationChanged
                }
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
                    self.updateGenerationMetadata(placeholder, editor: editor) { input in
                        input = storedInput
                    }
                }

                let params = buildParams(uploaded)

                await self.runJob(
                    placeholders: placeholders,
                    genInput: finalGenInput,
                    editor: editor,
                    onComplete: complete,
                    onFailure: fail,
                    submit: {
                        try await self.submitGeneration(finalGenInput.model, params, projectId)
                    }
                )
            } catch {
                if !(error is ProjectPackageCleanupError), Task.isCancelled || error is CancellationError {
                    self.cancelPlaceholders(placeholders, editor: editor, onFailure: fail)
                    return
                }
                let message = error.localizedDescription
                Log.generation.error("upload failed model=\(genInput.model) error=\(message)")
                for placeholder in placeholders {
                    self.updateGenerationMetadata(placeholder, editor: editor, status: .failed(
                        error is StartError ? message : "Upload failed: \(message)"
                    ))
                }
                editor.onProjectCheckpointRequired?()
                fail()
            }
        }

        return primaryId
    }

    private func captureSubmission(
        genInput: GenerationInput,
        assetType: ClipType,
        outputCount: Int,
        editor: EditorViewModel
    ) {
        var payload = Analytics.originProperties()
        payload["project_id"] = editor.projectId ?? "unknown"
        payload["model"] = genInput.model
        payload["generation_type"] = Self.generationType(assetType: assetType, genInput: genInput)
        payload["output_count"] = outputCount
        Analytics.capture(.generationSubmitted, properties: payload)
    }

    nonisolated static func generationType(assetType: ClipType, genInput: GenerationInput) -> String {
        genInput.upscaleSettings == nil ? assetType.rawValue : "upscale"
    }

    private func prepareReferences(
        references: [MediaAsset],
        trimmedSourceOverride: TrimmedSource?,
        preUploadedURLs: [String]?,
        preprocessRef: (@Sendable (Int, MediaAsset, URL) async throws -> URL?)?,
        preprocessSourceVideo: (@Sendable (URL) async throws -> URL?)?
    ) async throws -> PreparedReferences {
        if let preUploadedURLs, !preUploadedURLs.isEmpty {
            return PreparedReferences(uploaded: preUploadedURLs, tempFiles: [])
        }

        var tempFiles: [URL] = []
        do {
            try Task.checkCancellation()
            var urlsToUpload = references.map(\.url)
            let refTypes = references.map(\.type)
            var trimmedIndex: Int?
            if let trim = trimmedSourceOverride, trim.hasTrim,
               let index = urlsToUpload.firstIndex(of: trim.sourceURL) {
                Log.generation.notice("using trimmed source: frames \(trim.trimStartFrame)+\(trim.sourceFramesConsumed) of \(urlsToUpload[index].lastPathComponent)")
                let extracted = try await VideoTrimExtractor.extract(trim)
                urlsToUpload[index] = extracted
                tempFiles.append(extracted)
                trimmedIndex = index
            }
            if let preprocessSourceVideo, let sourceURL = urlsToUpload.first,
               let processed = try await preprocessSourceVideo(sourceURL) {
                urlsToUpload[0] = processed
                if processed != sourceURL, !references.contains(where: { $0.url == processed }) {
                    tempFiles.append(processed)
                }
            }
            if let preprocessRef, !references.isEmpty {
                let rewrites = try await preprocessedReferenceURLs(
                    references: references,
                    currentURLs: urlsToUpload,
                    preprocessRef: preprocessRef
                )
                for (i, rewritten) in rewrites {
                    guard let rewritten else { continue }
                    if rewritten != urlsToUpload[i], !references.contains(where: { $0.url == rewritten }) {
                        tempFiles.append(rewritten)
                    }
                    urlsToUpload[i] = rewritten
                }
            }
            let uploaded = try await uploadReferences(
                at: urlsToUpload,
                types: refTypes,
                cacheKeys: uploadCacheKeys(
                    references: references,
                    trimmedIndex: trimmedIndex,
                    hasPreprocess: preprocessRef != nil || preprocessSourceVideo != nil
                ),
            )
            return PreparedReferences(uploaded: uploaded, tempFiles: tempFiles)
        } catch {
            do { try await Self.cleanupTempFiles(tempFiles) }
            catch let cleanup { throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup) }
            throw error
        }
    }

    private func preprocessedReferenceURLs(
        references: [MediaAsset],
        currentURLs: [URL],
        preprocessRef: @escaping @Sendable (Int, MediaAsset, URL) async throws -> URL?
    ) async throws -> [(Int, URL?)] {
        let outcome = await withTaskGroup(of: (Int, Result<URL?, Error>).self) { group in
            var results: [(Int, URL?)] = []
            var failure: Error?
            var next = 0
            var running = 0
            while next < references.count || running > 0 {
                while failure == nil, !Task.isCancelled, next < references.count, running < 2 {
                    let index = next
                    let asset = references[index]
                    let currentURL = currentURLs[index]
                    group.addTask {
                        do { return (index, .success(try await preprocessRef(index, asset, currentURL))) }
                        catch { return (index, .failure(error)) }
                    }
                    next += 1
                    running += 1
                }
                guard running > 0, let (index, result) = await group.next() else { break }
                running -= 1
                switch result {
                case .success(let url): results.append((index, url))
                case .failure(let error):
                    if failure == nil { failure = error }
                    group.cancelAll()
                }
            }
            return (results, failure)
        }
        if let failure = outcome.1 ?? (Task.isCancelled ? CancellationError() : nil) {
            let temporaryURLs = outcome.0.compactMap(\.1).filter { url in
                !currentURLs.contains(url) && !references.contains(where: { $0.url == url })
            }
            do { try await Self.cleanupTempFiles(temporaryURLs) }
            catch let cleanup { throw ProjectPackageCleanupError(operationError: failure, cleanupError: cleanup) }
            throw failure
        }
        return outcome.0
    }

    private func uploadCacheKeys(
        references: [MediaAsset],
        trimmedIndex: Int?,
        hasPreprocess: Bool
    ) -> [MediaAsset?] {
        references.enumerated().map { index, asset in
            if hasPreprocess { return nil }
            if index == trimmedIndex { return nil }
            return asset
        }
    }

    @concurrent static func cleanupTempFiles(_ urls: [URL]) async throws {
        var failure: Error?
        for url in urls {
            do { try FileManager.default.removeItem(at: url) }
            catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
            catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
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
        let destURL = destDir.appendingPathComponent("gen-\(id).\(fileExtension)")
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

    private enum DownloadSource {
        case projectRelative(String)
        case file(URL)

        init(assetURL: URL, projectURL: URL?) {
            let source = assetURL.standardizedFileURL
            if let projectURL {
                let prefix = projectURL.standardizedFileURL.path + "/"
                if source.path.hasPrefix(prefix) {
                    self = .projectRelative(String(source.path.dropFirst(prefix.count)))
                    return
                }
            }
            self = .file(source)
        }

        func resolvedURL(projectURL: URL?) -> URL? {
            switch self {
            case .projectRelative(let path): projectURL?.appendingPathComponent(path).standardizedFileURL
            case .file(let url): url
            }
        }
    }

    private struct DownloadAttempt {
        let id: UUID
        let backendJobId: String?
        let outputIndex: Int?
        let source: DownloadSource
        var preparationContext: MediaAsset.PreparationContext
    }

    private func beginDownload(asset: MediaAsset, editor: EditorViewModel) -> DownloadAttempt? {
        guard !Task.isCancelled, downloadAttempts[asset.id] == nil,
              editor.mediaAssetsById[asset.id] === asset else { return nil }
        let attempt = DownloadAttempt(
            id: UUID(), backendJobId: asset.generationInput?.backendJobId,
            outputIndex: asset.generationInput?.outputIndex,
            source: DownloadSource(assetURL: asset.url, projectURL: editor.projectURL),
            preparationContext: asset.preparationContext
        )
        downloadAttempts[asset.id] = attempt.id
        return attempt
    }

    private func isCurrentDownload(_ attempt: DownloadAttempt, asset: MediaAsset, editor: EditorViewModel) -> Bool {
        !editor.projectPackageCoordinator.isClosed && editor.mediaAssetsById[asset.id] === asset
            && downloadAttempts[asset.id] == attempt.id
            && asset.generationInput?.backendJobId == attempt.backendJobId
            && asset.generationInput?.outputIndex == attempt.outputIndex
    }

    private func endDownload(_ attempt: DownloadAttempt, asset: MediaAsset) {
        if downloadAttempts[asset.id] == attempt.id { downloadAttempts.removeValue(forKey: asset.id) }
    }

    private func isCurrentDownload(
        _ attempt: DownloadAttempt, asset: MediaAsset, editor: EditorViewModel,
        expectedContext: MediaAsset.PreparationContext?
    ) -> Bool {
        guard isCurrentDownload(attempt, asset: asset, editor: editor) else { return false }
        let current = asset.preparationContext
        if let expectedContext { return current == expectedContext }
        guard let sourceURL = attempt.source.resolvedURL(projectURL: editor.projectURL) else { return false }
        return asset.url.standardizedFileURL == sourceURL
            && current.status == attempt.preparationContext.status
            && current.importInput == attempt.preparationContext.importInput
            && current.isGenerated == attempt.preparationContext.isGenerated
    }

    private func failDownload(
        _ error: Error, attempt: DownloadAttempt, asset: MediaAsset, remoteURL: URL,
        expectedContext: MediaAsset.PreparationContext?, editor: EditorViewModel
    ) {
        if error is ProjectPackageCleanupError || !(error is CancellationError) {
            Log.generation.error("download failed asset=\(asset.id): \(error.localizedDescription)")
        }
        guard isCurrentDownload(attempt, asset: asset, editor: editor, expectedContext: expectedContext) else { return }
        let canceled = !(error is ProjectPackageCleanupError) && (Task.isCancelled || error is CancellationError)
        asset.pendingDownloadURL = remoteURL
        updateGenerationMetadata(asset, editor: editor, status: .failed(
            canceled ? L10n.key("Generation canceled.") : error.localizedDescription
        ))
        editor.onProjectCheckpointRequired?()
    }

    @discardableResult
    func downloadAndFinalize(
        asset: MediaAsset, remoteURL: URL, editor: EditorViewModel,
        loadMetadata: MediaAssetMetadata.Loader = MediaAssetMetadata.load,
        identify: @Sendable (URL) async throws -> MediaInputIdentity = { try await MediaInputIdentityService.shared.identify($0) },
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil
    ) async -> Bool {
        guard let attempt = beginDownload(asset: asset, editor: editor) else { return false }
        defer { endDownload(attempt, asset: asset) }
        return await performDownload(
            attempt, asset: asset, remoteURL: remoteURL, editor: editor,
            loadMetadata: loadMetadata, identify: identify, onComplete: onComplete
        )
    }

    private func performDownload(
        _ attempt: DownloadAttempt, asset: MediaAsset, remoteURL: URL, editor: EditorViewModel,
        loadMetadata: MediaAssetMetadata.Loader = MediaAssetMetadata.load,
        identify: @Sendable (URL) async throws -> MediaInputIdentity = { try await MediaInputIdentityService.shared.identify($0) },
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil
    ) async -> Bool {
        var expectedContext: MediaAsset.PreparationContext?
        do {
            return try await editor.projectPackageCoordinator.withMutation { lease in
                do {
                    try Task.checkCancellation()
                    guard self.isCurrentDownload(attempt, asset: asset, editor: editor, expectedContext: nil),
                          let originalURL = attempt.source.resolvedURL(projectURL: editor.projectURL),
                          asset.url.standardizedFileURL == originalURL else { throw CancellationError() }
                    self.updateGenerationMetadata(asset, editor: editor, status: .downloading)
                    expectedContext = asset.preparationContext
                    let downloaded = try await self.downloadMedia(remoteURL)
                    do {
                        try Task.checkCancellation()
                    } catch {
                        do { try await Self.cleanupTempFiles([downloaded.fileURL]) }
                        catch let cleanup { throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup) }
                        throw error
                    }
                    let realExt = remoteURL.pathExtension.lowercased()
                    let ext = ClipType(fileExtension: realExt) != nil ? realExt : originalURL.pathExtension
                    let filename = "gen-\(asset.id)-\(attempt.id.uuidString).\(ext)"
                    _ = try await editor.commitStagedProjectMedia(
                        downloaded.fileURL, filename: filename, lease: lease, validate: {
                            try Task.checkCancellation()
                            guard self.isCurrentDownload(
                                attempt, asset: asset, editor: editor, expectedContext: expectedContext
                            ) else { throw CancellationError() }
                            if let status = downloaded.httpStatusCode, !(200..<300).contains(status) {
                                throw URLError(.badServerResponse)
                            }
                        }
                    ) { destination in
                        asset.url = destination
                        asset.pendingDownloadURL = nil
                        editor.importMediaAsset(asset, skipAppend: true)
                        expectedContext = asset.preparationContext
                    }
                    guard self.isCurrentDownload(
                        attempt, asset: asset, editor: editor, expectedContext: expectedContext
                    ) else { return false }
                    var publishedTerminal = false
                    let finalized = await editor.finalizeImportedAsset(
                        asset, loadMetadata: loadMetadata, identify: identify, onTerminalPublication: { context in
                            expectedContext = context
                            publishedTerminal = true
                        }
                    )
                    guard self.isCurrentDownload(
                        attempt, asset: asset, editor: editor, expectedContext: expectedContext
                    ) else { return false }
                    guard publishedTerminal else { throw CancellationError() }
                    if finalized {
                        onComplete?(asset)
                    } else {
                        asset.pendingDownloadURL = remoteURL
                    }
                    editor.onProjectCheckpointRequired?()
                    return finalized
                } catch {
                    self.failDownload(error, attempt: attempt, asset: asset, remoteURL: remoteURL, expectedContext: expectedContext, editor: editor)
                    return false
                }
            }
        } catch {
            failDownload(error, attempt: attempt, asset: asset, remoteURL: remoteURL, expectedContext: expectedContext, editor: editor)
            return false
        }
    }

    func retryDownload(asset: MediaAsset, editor: EditorViewModel) throws {
        try requireAvailable(editor: editor)
        guard let remoteURL = asset.pendingDownloadURL, !asset.isGenerating,
               var attempt = beginDownload(asset: asset, editor: editor) else { return }
        updateGenerationMetadata(asset, editor: editor, status: .downloading)
        attempt.preparationContext = asset.preparationContext
        var started = false
        launch(onCancellation: {
            if !started {
                self.failDownload(CancellationError(), attempt: attempt, asset: asset, remoteURL: remoteURL, expectedContext: nil, editor: editor)
            }
        }, onFinish: {
            self.endDownload(attempt, asset: asset)
        }) {
            started = true
            await self.performDownload(attempt, asset: asset, remoteURL: remoteURL, editor: editor)
        }
    }

    @discardableResult
    func enhanceDraft(asset: MediaAsset, editor: EditorViewModel) throws -> String {
        try requireAvailable(editor: editor)
        guard editor.mediaAssetsById[asset.id] === asset, asset.canEnhanceDraft,
              let originalInput = asset.generationInput,
              let sourceJobId = originalInput.backendJobId, !sourceJobId.isEmpty else { throw StartError.invalidDraft }
        var enhancedInput = originalInput
        enhancedInput.draft = false
        enhancedInput.resolution = "1080p"
        enhancedInput.backendJobId = nil
        enhancedInput.resultURLs = nil
        enhancedInput.costCredits = nil
        enhancedInput.refundedCredits = nil
        enhancedInput.createdAt = Date()
        let placeholder = createPlaceholder(
            type: .video,
            name: "\(asset.name) 1080p",
            duration: asset.resolvedDuration,
            genInput: enhancedInput,
            folderId: asset.folderId,
            destDir: Self.destinationDirectory(for: editor.projectURL),
            fileExtension: "mp4",
            editor: editor
        )

        let failureFlag = FirstOnlyFlag()
        var completedOutput = false
        let onFailure: @MainActor () -> Void = {
            guard failureFlag.fire() else { return }
            if case .failed(let message) = placeholder.generationStatus {
                editor.mediaPanelToast = MediaPanelToast(message: Self.localizedFailureMessage(message))
            } else if Task.isCancelled {
                editor.mediaPanelToast = MediaPanelToast(message: L10n.string("Generation canceled."))
            }
        }
        launch(onCancellation: {
            if !self.cancelPlaceholders([placeholder], editor: editor, onFailure: onFailure), !completedOutput { onFailure() }
        }) {
            await self.runJob(
                placeholders: [placeholder],
                genInput: enhancedInput,
                editor: editor,
                onComplete: { _ in
                    completedOutput = true
                    editor.mediaPanelToast = MediaPanelToast(
                        message: L10n.string("Enhanced with FLUX.3 at 1080p."),
                        kind: .success
                    )
                },
                onFailure: onFailure,
                submit: {
                    try await GenerationBackend.enhanceDraft(sourceJobId: sourceJobId)
                }
            )
        }
        return placeholder.id
    }

    func enhanceDraftFromUI(asset: MediaAsset, editor: EditorViewModel) {
        do { try enhanceDraft(asset: asset, editor: editor) }
        catch {
            editor.mediaPanelToast = MediaPanelToast(
                message: (error as? StartError)?.localizedMessage ?? error.localizedDescription
            )
        }
    }

    func resumePendingGenerations(editor: EditorViewModel) {
        guard !editor.projectPackageCoordinator.isClosing, !editor.projectPackageCoordinator.isClosed,
              !Task.isCancelled, suspensionWaiterCount == 0 else { return }
        isSuspending = false
        func sorted(_ assets: [MediaAsset]) -> [MediaAsset] {
            assets.sorted {
                let left = $0.generationInput?.outputIndex ?? 0
                let right = $1.generationInput?.outputIndex ?? 0
                return left < right
            }
        }

        let pending = editor.mediaAssets.filter {
            $0.isRecoveringGeneration || ($0.canResumeGeneration && (
                $0.generationStatus == .failed("Generation canceled.")
                    || $0.generationStatus == .failed("Generation monitoring interrupted.")
                    || $0.generationStatus == .failed("Backend not configured")
            ))
        }

        let byBackendJob = Dictionary(grouping: pending.compactMap { asset -> (String, MediaAsset)? in
            guard let backendJobId = asset.generationInput?.backendJobId, !backendJobId.isEmpty else { return nil }
            return (backendJobId, asset)
        }, by: { $0.0 })

        for (backendJobId, group) in byBackendJob where !resumedBackendJobIds.contains(backendJobId) {
            let placeholders = sorted(group.map { $0.1 })
            resumedBackendJobIds.insert(backendJobId)
            launch(
                onCancellation: {
                    self.cancelPlaceholders(placeholders, editor: editor, backendJobId: backendJobId, onFailure: nil)
                },
                onFinish: { self.resumedBackendJobIds.remove(backendJobId) }
            ) { [weak self, weak editor] in
                guard let self, let editor else { return }
                guard !Task.isCancelled else { return }
                for placeholder in placeholders where placeholder.generationInput?.backendJobId == backendJobId {
                    self.updateGenerationMetadata(placeholder, editor: editor, status: .generating)
                }
                await self.monitorBackendJob(
                    backendJobId: backendJobId,
                    placeholders: placeholders,
                    editor: editor,
                    onComplete: nil,
                    onFailure: nil
                )
            }
        }
    }

    private func backendError(_ error: Error) -> (code: String?, message: String) {
        struct Payload: Decodable { let code: String?; let message: String? }
        if case let ClientError.ConvexError(data) = error,
           let json = data.data(using: .utf8),
           let payload = try? JSONDecoder().decode(Payload.self, from: json),
           let message = payload.message {
            return (payload.code, message)
        }
        return (nil, error.localizedDescription)
    }

    private func updateGenerationMetadata(
        _ asset: MediaAsset,
        editor: EditorViewModel,
        status: MediaAsset.GenerationStatus? = nil,
        mutateInput: ((inout GenerationInput) -> Void)? = nil
    ) {
        guard editor.mediaAssetsById[asset.id] === asset, !editor.projectPackageCoordinator.isClosed else { return }
        if let status {
            asset.generationStatus = status
        }
        if let mutateInput, var input = asset.generationInput {
            mutateInput(&input)
            asset.generationInput = input
        }
        editor.updateManifestMetadata(for: [asset])
    }

    /// Uploads each reference and returns the hosted URLs.
    private func uploadReferences(
        at urls: [URL],
        types: [ClipType],
        cacheKeys: [MediaAsset?],
    ) async throws -> [String] {
        guard !urls.isEmpty else { return [] }
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var next = 0
            var running = 0
            var results: [(Int, String)] = []
            while next < urls.count || running > 0 {
                try Task.checkCancellation()
                while next < urls.count, running < 2 {
                    let i = next
                    let url = urls[i]
                    next += 1
                    running += 1
                    let type = types.indices.contains(i) ? types[i] : .image
                    let cacheKey = cacheKeys.indices.contains(i) ? cacheKeys[i] : nil
                    let requiresConversion = type == .image && ImageConverter.requiresConversion(url)
                    if !requiresConversion, let cacheKey, let hit = cacheKey.freshRemoteURL {
                        group.addTask { (i, hit) }
                        continue
                    }
                    let contentType = requiresConversion ? "image/jpeg" : Self.contentType(for: url, fallback: type)
                    group.addTask {
                        let convertedURL = requiresConversion ? try await ImageConverter.convertToJPEG(url) : nil
                        do {
                            let uploaded = try await GenerationBackend.uploadReference(
                                fileURL: convertedURL ?? url, contentType: contentType)
                            if let convertedURL { try await Self.cleanupTempFiles([convertedURL]) }
                            if !requiresConversion, let cacheKey {
                                await Self.recordUploadCache(asset: cacheKey, sourceURL: url, url: uploaded)
                            }
                            return (i, uploaded)
                        } catch {
                            if let convertedURL {
                                do { try await Self.cleanupTempFiles([convertedURL]) }
                                catch let cleanup { throw ProjectPackageCleanupError(operationError: error, cleanupError: cleanup) }
                            }
                            throw error
                        }
                    }
                }
                if let result = try await group.next() {
                    results.append(result)
                    running -= 1
                }
            }
            return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    @MainActor
    private static func recordUploadCache(asset: MediaAsset, sourceURL: URL, url: String) {
        guard !Task.isCancelled, asset.url == sourceURL else { return }
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
        case "caf": return "audio/x-caf"
        case "flac": return "audio/flac"
        default:
            switch fallback {
            case .image: return "image/jpeg"
            case .video: return "video/mp4"
            case .audio: return "audio/mpeg"
            case .text, .subtitle: return "application/octet-stream"
            case .lottie: return "application/json"
            case .sequence: return "video/mp4"
            }
        }
    }

    // MARK: - Job execution

    private func runJob(
        placeholders: [MediaAsset],
        genInput: GenerationInput,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?,
        submit: () async throws -> String
    ) async {
        let runId = String(UUID().uuidString.prefix(8))
        Log.generation.notice("run \(runId) start model=\(genInput.model) placeholders=\(placeholders.count)")
        defer { Log.generation.notice("run \(runId) settled") }

        let jobId: String
        do {
            try Task.checkCancellation()
            guard placeholders.contains(where: { editor.mediaAssetsById[$0.id] === $0 }) else {
                onFailure?()
                return
            }
            jobId = try await submit()
            guard !jobId.isEmpty else { throw CocoaError(.coderInvalidValue) }
        } catch {
            if Task.isCancelled || error is CancellationError {
                cancelPlaceholders(placeholders, editor: editor, onFailure: onFailure)
                return
            }
            let (code, message) = backendError(error)
            let expected: Set<String> = [
                "insufficient_credits", "subscription_required", "plan_required",
                "rate_limited", "invalid_params",
            ]
            if let code, expected.contains(code) {
                Log.generation.warning("submit failed model=\(genInput.model) code=\(code) error=\(message)")
            } else {
                Log.generation.error("submit failed model=\(genInput.model) error=\(message)")
            }
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

        guard !Task.isCancelled else { return }
        guard resumedBackendJobIds.insert(jobId).inserted else { return }
        defer { resumedBackendJobIds.remove(jobId) }

        await monitorBackendJob(
            backendJobId: jobId,
            placeholders: placeholders,
            editor: editor,
            onComplete: onComplete,
            onFailure: onFailure
        )
    }

    private func monitorBackendJob(
        backendJobId: String,
        placeholders: [MediaAsset],
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) async {
        guard !Task.isCancelled else { return }
        guard let publisher = subscribe(backendJobId) else {
            for placeholder in placeholders {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed("Backend not configured"))
            }
            editor.onProjectCheckpointRequired?()
            onFailure?()
            return
        }

        for await jobOpt in backendJobStream(from: publisher) {
            guard !Task.isCancelled else { return }
            guard let job = jobOpt, job._id == backendJobId else { continue }
            let current = placeholders.filter {
                editor.mediaAssetsById[$0.id] === $0 && $0.generationInput?.backendJobId == backendJobId
            }
            guard !current.isEmpty else { onFailure?(); return }
            if await applyBackendJobUpdate(
                job: job,
                backendJobId: backendJobId,
                placeholders: current,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            ) {
                return
            }
        }

        guard !Task.isCancelled else { return }
        let current = placeholders.filter {
            editor.mediaAssetsById[$0.id] === $0 && $0.generationInput?.backendJobId == backendJobId
        }
        let persisted = current.compactMap(\.generationInput?.resultURLs).first ?? []
        guard !persisted.isEmpty else {
            for placeholder in current {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed(L10n.key("Generation monitoring interrupted.")))
            }
            editor.onProjectCheckpointRequired?()
            onFailure?()
            return
        }
        await finalizeSuccess(
            urlStrings: persisted,
            backendJobId: backendJobId,
            placeholders: current,
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
                costCredits: job.costCredits,
                editor: editor
            ) {
                editor.onProjectCheckpointRequired?()
            }
            await finalizeSuccess(
                urlStrings: job.resultUrls ?? [],
                backendJobId: backendJobId,
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
                    if let costCredits = job.costCredits {
                        input.costCredits = costCredits
                    }
                    input.refundedCredits = job.refundedCredits
                }
            }
            editor.onProjectCheckpointRequired?()
            onFailure?()
            return true
        case .queued, .running:
            if updateBackendJobMetadata(
                placeholders,
                backendJobId: backendJobId,
                costCredits: job.costCredits,
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
        costCredits: Int?,
        editor: EditorViewModel
    ) -> Bool {
        var changed = false
        for placeholder in placeholders {
            guard placeholder.generationStatus != .downloading else { continue }
            let input = placeholder.generationInput
            let metadataUnchanged = placeholder.generationStatus == .generating
                && input?.backendJobId == backendJobId
                && (costCredits == nil || input?.costCredits == costCredits)
            guard !metadataUnchanged else { continue }
            updateGenerationMetadata(placeholder, editor: editor, status: .generating) { input in
                input.backendJobId = backendJobId
                if let costCredits {
                    input.costCredits = costCredits
                }
            }
            changed = true
        }
        return changed
    }

    private func finalizeSuccess(
        urlStrings: [String],
        backendJobId: String,
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
            guard !Task.isCancelled else { return }
            guard editor.mediaAssetsById[placeholder.id] === placeholder,
                  placeholder.generationInput?.backendJobId == backendJobId else { continue }
            let outputIndex = placeholder.generationInput?.outputIndex ?? i
            guard outputIndex >= 0, outputIndex < urlStrings.count,
                  let remote = URL(string: urlStrings[outputIndex]),
                  ["https", "http"].contains(remote.scheme?.lowercased() ?? ""), remote.host != nil else {
                updateGenerationMetadata(placeholder, editor: editor, status: .failed("No URL for placeholder"))
                continue
            }
            updateGenerationMetadata(placeholder, editor: editor, status: .downloading) { input in
                input.resultURLs = urlStrings
            }
            if await downloadAndFinalize(asset: placeholder, remoteURL: remote, editor: editor, onComplete: onComplete) {
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
