import Foundation
@preconcurrency import FalClient

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
        buildInput: @escaping ([String]) -> (endpoint: String, input: Payload),
        responseKeyPath: @escaping @Sendable (Payload) -> String?,
        fileExtension: String,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String {
        let placeholder = createPlaceholder(
            type: assetType,
            name: name ?? String(genInput.prompt.prefix(30)),
            duration: placeholderDuration,
            genInput: genInput,
            editor: editor
        )

        let placeholderId = placeholder.id
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
                    uploaded = try await uploadReferences(at: urlsToUpload)
                }

                var finalGenInput = genInput
                finalGenInput.imageURLs = uploaded.isEmpty ? nil : uploaded
                if finalGenInput.createdAt == nil {
                    finalGenInput.createdAt = Date()
                }
                placeholder.generationInput = finalGenInput

                let (endpoint, input) = buildInput(uploaded)

                self.runGeneration(
                    placeholder: placeholder,
                    endpoint: endpoint,
                    input: input,
                    responseKeyPath: responseKeyPath,
                    fileExtension: fileExtension,
                    assetType: assetType,
                    genInput: finalGenInput,
                    projectURL: projectURL,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            } catch {
                Log.generation.error("upload failed model=\(genInput.model) error=\(error.localizedDescription)")
                placeholder.generationStatus = .failed("Upload failed: \(error.localizedDescription)")
                onFailure?()
            }
        }

        return placeholderId
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
        editor: EditorViewModel
    ) -> MediaAsset {
        let placeholder = MediaAsset(
            url: URL(fileURLWithPath: "/dev/null"),
            type: type,
            name: name,
            duration: duration,
            generationInput: genInput
        )
        placeholder.generationStatus = .generating
        editor.mediaAssets.append(placeholder)
        return placeholder
    }

    private func runGeneration(
        placeholder: MediaAsset,
        endpoint: String,
        input: Payload,
        responseKeyPath: @escaping @Sendable (Payload) -> String?,
        fileExtension: String,
        assetType: ClipType,
        genInput: GenerationInput,
        projectURL: URL?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) {
        guard hasApiKey else { return }
        let key = apiKey
        let placeholderId = placeholder.id

        Task { @MainActor in
            do {
                Log.generation.notice("subscribe start endpoint=\(endpoint) model=\(genInput.model)")
                let urlString: String? = try await {
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

                guard let urlString, let remoteURL = URL(string: urlString) else {
                    Log.generation.error("subscribe ok but no URL in response model=\(genInput.model)")
                    placeholder.generationStatus = .failed("No URL in response")
                    onFailure?()
                    return
                }

                Log.generation.notice("downloading \(remoteURL.host ?? "?")")
                let (tempURL, _) = try await URLSession.shared.download(from: remoteURL)
                let filename = "gen-\(placeholderId.prefix(8)).\(fileExtension)"
                let data = try Data(contentsOf: tempURL)
                try? FileManager.default.removeItem(at: tempURL)

                let destURL: URL
                if let projectURL {
                    let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
                    try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
                    destURL = mediaDir.appendingPathComponent(filename)
                } else {
                    destURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
                }
                try data.write(to: destURL)

                if let idx = editor.mediaAssets.firstIndex(where: { $0.id == placeholderId }) {
                    let asset = MediaAsset(
                        id: placeholderId,
                        url: destURL,
                        type: assetType,
                        name: placeholder.name,
                        duration: placeholder.duration,
                        generationInput: genInput
                    )
                    editor.mediaAssets[idx] = asset
                    editor.importMediaAsset(asset, skipAppend: true)
                    await editor.finalizeImportedAsset(asset)
                    onComplete?(asset)
                }
            } catch {
                Log.generation.error("generation failed model=\(genInput.model) error=\(error.localizedDescription)")
                placeholder.generationStatus = .failed(error.localizedDescription)
                onFailure?()
            }
        }
    }
}
