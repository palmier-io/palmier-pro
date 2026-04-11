import Foundation
@preconcurrency import FalClient

@Observable
@MainActor
final class GenerationService {
    private var apiKey: String { UserDefaults.standard.string(forKey: "falApiKey") ?? "" }

    var hasApiKey: Bool { !apiKey.isEmpty }

    // MARK: - Video generation

    func generateVideo(
        model: VideoModelConfig,
        prompt: String,
        duration: Int,
        aspectRatio: String,
        resolution: String?,
        projectURL: URL?,
        editor: EditorViewModel
    ) {
        let genInput = GenerationInput(
            prompt: prompt,
            model: model.displayName,
            duration: duration,
            aspectRatio: aspectRatio,
            resolution: resolution
        )

        let placeholder = createPlaceholder(
            type: .video,
            name: "AI: \(prompt.prefix(30))",
            duration: Double(duration),
            genInput: genInput,
            editor: editor
        )

        let input = model.buildInput(prompt: prompt, duration: duration, aspectRatio: aspectRatio, resolution: resolution)
        let endpoint = model.endpoint

        runGeneration(
            placeholder: placeholder,
            endpoint: endpoint,
            input: input,
            responseKeyPath: { $0["video"]["url"].stringValue },
            fileExtension: "mp4",
            assetType: .video,
            genInput: genInput,
            projectURL: projectURL,
            editor: editor
        )
    }

    // MARK: - Image generation

    func generateImage(
        model: ImageModelConfig,
        prompt: String,
        aspectRatio: String,
        resolution: String?,
        projectURL: URL?,
        editor: EditorViewModel
    ) {
        let genInput = GenerationInput(
            prompt: prompt,
            model: model.displayName,
            duration: 0,
            aspectRatio: aspectRatio,
            resolution: resolution
        )

        let placeholder = createPlaceholder(
            type: .image,
            name: "AI: \(prompt.prefix(30))",
            duration: Defaults.imageDurationSeconds,
            genInput: genInput,
            editor: editor
        )

        let input = model.buildInput(prompt: prompt, aspectRatio: aspectRatio, resolution: resolution)
        let endpoint = model.endpoint

        runGeneration(
            placeholder: placeholder,
            endpoint: endpoint,
            input: input,
            responseKeyPath: { $0["images"][0]["url"].stringValue },
            fileExtension: "jpg",
            assetType: .image,
            genInput: genInput,
            projectURL: projectURL,
            editor: editor
        )
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
                        name: genInput.prompt.prefix(30).isEmpty ? "AI Generated" : "AI: \(genInput.prompt.prefix(30))",
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
