import Foundation
@preconcurrency import FalClient

@Observable
@MainActor
final class GenerationService {
    private var apiKey: String = FalKeychain.load() ?? ""

    var hasApiKey: Bool { !apiKey.isEmpty }

    var maskedApiKey: String {
        guard apiKey.count > 6 else { return String(repeating: "\u{2022}", count: apiKey.count) }
        return apiKey.prefix(3) + String(repeating: "\u{2022}", count: apiKey.count - 6) + apiKey.suffix(3)
    }

    func setApiKey(_ key: String) {
        FalKeychain.save(key)
        apiKey = key
    }

    func removeApiKey() {
        FalKeychain.delete()
        apiKey = ""
    }

    // MARK: - Generation

    func generate(
        genInput: GenerationInput,
        assetType: ClipType,
        placeholderDuration: Double,
        references: [MediaAsset] = [],
        buildInput: @escaping ([String]) -> (endpoint: String, input: Payload),
        responseKeyPath: @escaping @Sendable (Payload) -> String?,
        fileExtension: String,
        projectURL: URL?,
        editor: EditorViewModel
    ) {
        let placeholder = createPlaceholder(
            type: assetType,
            name: String(genInput.prompt.prefix(30)),
            duration: placeholderDuration,
            genInput: genInput,
            editor: editor
        )

        let refURLs = references.map(\.url)

        Task { @MainActor in
            do {
                let uploaded = try await uploadImages(at: refURLs)

                var finalGenInput = genInput
                finalGenInput.imageURLs = uploaded.isEmpty ? nil : uploaded
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
                    editor: editor
                )
            } catch {
                placeholder.generationStatus = .failed("Upload failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Image upload

    private func uploadImages(at urls: [URL]) async throws -> [String] {
        guard !urls.isEmpty else { return [] }
        let key = apiKey
        let client = FalClient.withCredentials(.keyPair(key))
        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for (i, url) in urls.enumerated() {
                group.addTask {
                    let data = try Data(contentsOf: url)
                    let ext = url.pathExtension.lowercased()
                    let fileType: FileType = switch ext {
                    case "png": .imagePng
                    case "webp": .imageWebp
                    case "gif": .imageGif
                    default: .imageJpeg
                    }
                    let uploaded = try await client.storage.upload(data: data, ofType: fileType)
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
        editor: EditorViewModel
    ) {
        guard hasApiKey else { return }
        let key = apiKey
        let placeholderId = placeholder.id

        Task { @MainActor in
            do {
                let urlString: String? = try await {
                    nonisolated(unsafe) let input = input
                    let responseKeyPath = responseKeyPath
                    let client = FalClient.withCredentials(.keyPair(key))
                    let result = try await client.subscribe(
                        to: endpoint,
                        input: input,
                        pollInterval: .seconds(2),
                        timeout: .seconds(300),
                        includeLogs: false,
                        onQueueUpdate: nil
                    )
                    return responseKeyPath(result)
                }()

                guard let urlString, let remoteURL = URL(string: urlString) else {
                    placeholder.generationStatus = .failed("No URL in response")
                    return
                }

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
                        name: genInput.prompt.prefix(30).isEmpty ? "Generated" : String(genInput.prompt.prefix(30)),
                        duration: placeholder.duration,
                        generationInput: genInput
                    )
                    editor.mediaAssets[idx] = asset
                    editor.importMediaAsset(asset, skipAppend: true)
                    Task { await asset.loadMetadata() }
                }
            } catch {
                placeholder.generationStatus = .failed(error.localizedDescription)
            }
        }
    }
}
