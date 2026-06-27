import Foundation

extension ToolExecutor {
    private static let analyzeVideoAllowedKeys: Set<String> = ["mediaRef", "prompt"]

    /// Pegasus video understanding. Opt-in: when no TwelveLabs key is set this returns a clear,
    /// non-fatal error so the rest of the agent is unchanged. Uploads the source asset to
    /// TwelveLabs and returns Pegasus's answer to the prompt.
    func analyzeVideo(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.analyzeVideoAllowedKeys, path: "analyze_video")

        let apiKey = await Task.detached(priority: .utility) { TwelveLabsKeychain.load() ?? "" }.value
        guard !apiKey.isEmpty else {
            return .error("TwelveLabs is not configured. Add an API key in Settings → Agent to enable video understanding, then retry. Until then, use inspect_media for on-device frame sampling and transcription.")
        }

        let mediaRef = try args.requireString("mediaRef")
        let prompt = try args.requireString("prompt").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ToolError("analyze_video: prompt is empty") }

        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .video else {
            throw ToolError("analyze_video only handles video assets — \(asset.name) is \(asset.type.rawValue). Use inspect_media for images and audio.")
        }
        let url = asset.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            switch asset.generationStatus {
            case .downloading:
                throw ToolError("Asset \(asset.id) is still downloading. Poll get_media and retry once generationStatus becomes 'none'.")
            case .generating:
                throw ToolError("Asset \(asset.id) is still generating. Poll get_media and retry once generationStatus becomes 'none'.")
            case .rendering:
                throw ToolError("Asset \(asset.id) is still rendering. Poll get_media and retry once generationStatus becomes 'none'.")
            case .failed(let msg):
                throw ToolError("Asset \(asset.id) failed: \(msg)")
            case .none:
                throw ToolError("Media file not on disk: \(url.lastPathComponent)")
            }
        }

        let client = TwelveLabsClient(apiKey: apiKey)
        let answer: String
        do {
            // Run off the main actor: building the multipart upload body streams the whole
            // source file from disk, which would otherwise block the editor on @MainActor.
            answer = try await Task.detached(priority: .userInitiated) {
                try await client.understand(videoURL: url, prompt: prompt)
            }.value
        } catch {
            Log.agent.warning("analyze_video failed: \(error.localizedDescription)")
            return .error("TwelveLabs analysis failed: \(error.localizedDescription)")
        }

        let payload: [String: Any] = [
            "mediaRef": asset.id,
            "name": asset.name,
            "model": "pegasus1.5",
            "answer": answer,
        ]
        guard let json = Self.jsonString(payload) else {
            throw ToolError("analyze_video: failed to encode result")
        }
        return .ok(json)
    }
}
