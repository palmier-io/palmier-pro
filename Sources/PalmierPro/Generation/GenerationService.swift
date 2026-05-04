import Foundation
@preconcurrency import FalClient

/// MainActor-only one-shot flag. Used by replace-clip callbacks so only the
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

@Observable
@MainActor
final class GenerationService {
    static let subscribeTimeoutSeconds: Int = 1800

    private static let credentialsFilename = "fal-credentials"

    private(set) var apiKey: String = FileCredentialStore.load(filename: credentialsFilename) ?? ""

    var hasApiKey: Bool { !apiKey.isEmpty }

    var maskedApiKey: String {
        guard apiKey.count > 6 else { return String(repeating: "\u{2022}", count: apiKey.count) }
        return apiKey.prefix(3) + String(repeating: "\u{2022}", count: apiKey.count - 6) + apiKey.suffix(3)
    }

    func setApiKey(_ key: String) {
        FileCredentialStore.save(key, filename: Self.credentialsFilename)
        apiKey = key
    }

    func removeApiKey() {
        FileCredentialStore.delete(filename: Self.credentialsFilename)
        apiKey = ""
    }

    // MARK: - Generation

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
        variantStackRootId: String? = nil,
        buildInput: @escaping ([String]) -> (endpoint: String, input: Payload),
        snapshotRefs: (@Sendable (inout GenerationInput, [String]) -> Void)? = nil,
        preprocessRef: (@Sendable (Int, MediaAsset) async throws -> URL?)? = nil,
        responseKeyPath: @escaping @Sendable (Payload) -> [String],
        fileExtension: String,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        let count = max(1, min(4, numImages))
        let baseName = name ?? String(genInput.prompt.prefix(30))

        // Validate if root still exists and same type
        let stackRootId = variantStackRootId.flatMap { rootId -> String? in
            guard let root = editor.mediaAssets.first(where: { $0.id == rootId }),
                  root.type == assetType else { return nil }
            return rootId
        }
        var placeholders: [MediaAsset] = []
        let destDir = Self.destinationDirectory(for: projectURL)

        // Group all N images into a stack
        for i in 0..<count {
            let parent: String?
            if let stackRootId {
                parent = stackRootId
            } else if i > 0, let firstId = placeholders.first?.id {
                parent = firstId
            } else {
                parent = nil
            }
            let placeholder = createPlaceholder(
                type: assetType,
                name: baseName,
                duration: placeholderDuration,
                genInput: genInput,
                parentAssetId: parent,
                destDir: destDir,
                fileExtension: fileExtension,
                editor: editor
            )
            placeholders.append(placeholder)
        }
        let primaryId = placeholders[0].id
        let refURLs = references.map(\.url)

        Task { @MainActor in
            var tempToCleanup: [URL] = []
            defer { Self.cleanupTempFiles(tempToCleanup) }
            do {
                let uploaded: [String]
                if let preUploadedURLs, !preUploadedURLs.isEmpty {
                    uploaded = preUploadedURLs
                } else {
                    var urlsToUpload = refURLs
                    if let trim = trimmedSourceOverride, trim.hasTrim, !urlsToUpload.isEmpty {
                        Log.generation.notice("using trimmed source: frames \(trim.trimStartFrame)+\(trim.sourceFramesConsumed) of \(urlsToUpload[0].lastPathComponent)")
                        let extracted = try await VideoTrimExtractor.extract(trim)
                        urlsToUpload[0] = extracted
                        tempToCleanup.append(extracted)
                    }
                    if let preprocessRef, !references.isEmpty {
                        let snapshot = references
                        let rewrites: [(Int, URL?)] = try await withThrowingTaskGroup(of: (Int, URL?).self) { group in
                            for (i, asset) in snapshot.enumerated() {
                                group.addTask { (i, try await preprocessRef(i, asset)) }
                            }
                            var results: [(Int, URL?)] = []
                            for try await r in group { results.append(r) }
                            return results
                        }
                        for (i, rewritten) in rewrites {
                            if let rewritten {
                                urlsToUpload[i] = rewritten
                                tempToCleanup.append(rewritten)
                            }
                        }
                    }
                    uploaded = try await uploadReferences(at: urlsToUpload)
                }

                var finalGenInput = genInput
                if let snapshotRefs {
                    snapshotRefs(&finalGenInput, uploaded)
                } else {
                    finalGenInput.imageURLs = uploaded.isEmpty ? nil : uploaded
                }
                if finalGenInput.createdAt == nil {
                    finalGenInput.createdAt = Date()
                }
                for placeholder in placeholders {
                    placeholder.generationInput = finalGenInput
                }

                let (endpoint, input) = buildInput(uploaded)

                self.runGeneration(
                    placeholders: placeholders,
                    endpoint: endpoint,
                    input: input,
                    responseKeyPath: responseKeyPath,
                    genInput: finalGenInput,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            } catch {
                let message = Self.friendlyMessage(from: error)
                Log.generation.error("upload failed model=\(genInput.model) error=\(message)")
                for placeholder in placeholders {
                    placeholder.generationStatus = .failed("Upload failed: \(message)")
                }
                onFailure?()
            }
        }

        return primaryId
    }

    private static func cleanupTempFiles(_ urls: [URL]) {
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Reference upload

    private func uploadReferences(at urls: [URL]) async throws -> [String] {
        guard !urls.isEmpty else { return [] }
        let key = apiKey
        let client = FalClient.withCredentials(.keyPair(key))
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    let data = try Data(contentsOf: url)
                    let uploaded = try await client.storage.upload(data: data, ofType: .inferred(from: url))
                    return (i, uploaded)
                }
            }
            var results = [(Int, String)]()
            for try await result in group { results.append(result) }
            return results.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    // MARK: - Shared

    private func createPlaceholder(
        type: ClipType,
        name: String,
        duration: Double,
        genInput: GenerationInput,
        parentAssetId: String?,
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
        placeholder.generationStatus = .generating
        placeholder.parentAssetId = parentAssetId
        editor.mediaAssets.append(placeholder)
        return placeholder
    }

    private static func destinationDirectory(for projectURL: URL?) -> URL {
        if let projectURL {
            let dir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        return FileManager.default.temporaryDirectory
    }

    private func runGeneration(
        placeholders: [MediaAsset],
        endpoint: String,
        input: Payload,
        responseKeyPath: @escaping @Sendable (Payload) -> [String],
        genInput: GenerationInput,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) {
        guard hasApiKey else { return }
        let key = apiKey
        let runId = String(UUID().uuidString.prefix(8))

        Task { @MainActor in
            Log.generation.notice("run \(runId) start endpoint=\(endpoint) model=\(genInput.model) placeholders=\(placeholders.count)")
            defer { Log.generation.notice("run \(runId) settled") }
            do {
                Log.generation.notice("subscribe start endpoint=\(endpoint) model=\(genInput.model)")
                let urlStrings: [String] = try await {
                    nonisolated(unsafe) let input = input
                    let responseKeyPath = responseKeyPath
                    let client = FalClient.withCredentials(.keyPair(key))
                    let result = try await client.subscribe(
                        to: endpoint,
                        input: input,
                        pollInterval: .seconds(2),
                        timeout: .seconds(Self.subscribeTimeoutSeconds),
                        includeLogs: false,
                        onQueueUpdate: nil
                    )
                    return responseKeyPath(result)
                }()

                if urlStrings.isEmpty {
                    Log.generation.error("subscribe ok but no URL in response model=\(genInput.model)")
                    for placeholder in placeholders {
                        placeholder.generationStatus = .failed("No URL in response")
                    }
                    onFailure?()
                    return
                }

                if urlStrings.count < placeholders.count {
                    Log.generation.notice("fal returned \(urlStrings.count) URL(s) for \(placeholders.count) placeholder(s); marking extras as failed")
                }

                var anyFinalized = false
                for (i, placeholder) in placeholders.enumerated() {
                    guard i < urlStrings.count, let remoteURL = URL(string: urlStrings[i]) else {
                        placeholder.generationStatus = .failed("No image in response")
                        continue
                    }
                    do {
                        Log.generation.notice("downloading \(remoteURL.host ?? "?") (\(i + 1)/\(urlStrings.count))")
                        let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
                        try? FileManager.default.removeItem(at: placeholder.url)
                        try FileManager.default.moveItem(at: tempURL, to: placeholder.url)

                        placeholder.generationStatus = .none
                        editor.importMediaAsset(placeholder, skipAppend: true)
                        editor.appendGenerationLog(for: placeholder)
                        await editor.finalizeImportedAsset(placeholder)
                        onComplete?(placeholder)
                        anyFinalized = true
                    } catch {
                        let message = Self.friendlyMessage(from: error)
                        Log.generation.error("download failed model=\(genInput.model) idx=\(i) error=\(message)")
                        placeholder.generationStatus = .failed(message)
                    }
                }

                if !anyFinalized {
                    onFailure?()
                }
            } catch {
                let message = Self.friendlyMessage(from: error)
                Log.generation.error("generation failed model=\(genInput.model) error=\(message)")
                for placeholder in placeholders {
                    placeholder.generationStatus = .failed(message)
                }
                onFailure?()
            }
        }
    }

    /// Extracts a user-friendly error message from FalError using reflection.
    static func friendlyMessage(from error: Error) -> String {
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum,
              let child = mirror.children.first,
              let label = child.label else {
            return error.localizedDescription
        }
        let fields = Dictionary(
            Mirror(reflecting: child.value).children.compactMap { c in
                c.label.map { ($0, c.value) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        switch label {
        case "httpError":
            let status = fields["status"] as? Int ?? 0
            let detail = detailMessage(from: fields["payload"] as? Payload)
                ?? fields["message"] as? String
            return detail.map { "\($0) (HTTP \(status))" } ?? "HTTP \(status)"
        case "unauthorized":
            return (fields["message"] as? String).map { "Unauthorized: \($0)" } ?? "Unauthorized"
        case "queueTimeout":
            return "Generation timed out"
        default:
            return error.localizedDescription
        }
    }

    /// fal returns either `{"detail": "msg"}` or FastAPI's `{"detail": [{"msg": "..."}]}`.
    private static func detailMessage(from payload: Payload?) -> String? {
        guard let payload else { return nil }
        let detail = payload["detail"]
        if let str = detail.stringValue { return str }
        guard case let .array(items) = detail else { return nil }
        let msgs = items.compactMap { $0["msg"].stringValue ?? $0.stringValue }
        return msgs.isEmpty ? nil : msgs.joined(separator: "; ")
    }
}
