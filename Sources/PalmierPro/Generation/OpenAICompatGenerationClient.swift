import Foundation

/// Talks to an OpenAI-compatible image endpoint (a LiteLLM gateway). Reuses the agent
/// gateway's base URL + key (`GatewayConfig` / `GatewayKeychain`) since the same gateway
/// serves chat and generation. Images come back synchronously — no job/poll loop.
struct OpenAICompatGenerationClient: Sendable {
    let baseURL: URL
    let apiKey: String

    /// True when an OpenAI-compatible gateway base URL is configured (the fork default).
    /// Generation routes to the gateway whenever this holds.
    @MainActor
    static var gatewayConfigured: Bool {
        let raw = GatewayConfig.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw) else { return false }
        // Mirror AgentService.hasGateway: a remote gateway activates only once a key is set,
        // so the pre-filled default can't be turned on by an accidental Save; loopback (local)
        // gateways need no key.
        if !(GatewayKeychain.load() ?? "").isEmpty { return true }
        let host = url.host?.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Build from the configured agent gateway, or nil if it isn't set.
    @MainActor
    static func fromGateway() -> OpenAICompatGenerationClient? {
        let raw = GatewayConfig.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let url = URL(string: raw) else { return nil }
        return OpenAICompatGenerationClient(baseURL: url, apiKey: GatewayKeychain.load() ?? "")
    }

    /// POST /images/generations; returns the generated images as remote URLs or local
    /// files (base64 responses are written to temp files).
    func generateImages(model: String, prompt: String, n: Int, size: String?) async throws -> [URL] {
        let endpoint = baseURL.appendingPathComponent("images/generations")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        var body: [String: Any] = ["model": model, "prompt": prompt, "n": max(1, n)]
        if let size, !size.isEmpty { body["size"] = size }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw OpenAICompatGenerationError.httpError(
                status: http.statusCode, body: String(data: data, encoding: .utf8) ?? ""
            )
        }

        var urls: [URL] = []
        for image in try Self.decodeImages(from: data) {
            switch image {
            case .url(let u):
                urls.append(u)
            case .base64(let bytes):
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("genimg-\(UUID().uuidString.prefix(8)).png")
                try bytes.write(to: tmp)
                urls.append(tmp)
            }
        }
        return urls
    }

    // MARK: - Model discovery

    struct GatewayModel: Sendable, Equatable {
        let id: String
        let mode: String?   // LiteLLM model_info.mode (e.g. "image_generation"); nil from plain /v1/models
    }

    /// List the gateway's models. Prefers LiteLLM `/model/info` (carries modality);
    /// falls back to the OpenAI-standard `/v1/models` (ids only).
    func listModels() async throws -> [GatewayModel] {
        if let info = try? await fetchModelInfo(), !info.isEmpty { return info }
        return try await fetchBasicModels()
    }

    private func authedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func fetchModelInfo() async throws -> [GatewayModel] {
        guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw OpenAICompatGenerationError.decodeFailed
        }
        comps.path = "/model/info"   // LiteLLM mgmt endpoint lives at the gateway root
        comps.query = nil
        guard let url = comps.url else { throw OpenAICompatGenerationError.decodeFailed }
        let (data, response) = try await URLSession.shared.data(for: authedRequest(url))
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw OpenAICompatGenerationError.httpError(status: http.statusCode, body: "")
        }
        return Self.parseModelInfo(data)
    }

    private func fetchBasicModels() async throws -> [GatewayModel] {
        let url = baseURL.appendingPathComponent("models")
        let (data, response) = try await URLSession.shared.data(for: authedRequest(url))
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw OpenAICompatGenerationError.httpError(
                status: http.statusCode, body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        return Self.parseBasicModels(data)
    }

    static func parseModelInfo(_ data: Data) -> [GatewayModel] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let name = (item["model_name"] as? String) ?? (item["id"] as? String) else { return nil }
            let mode = (item["model_info"] as? [String: Any])?["mode"] as? String
            return GatewayModel(id: name, mode: mode)
        }
    }

    static func parseBasicModels(_ data: Data) -> [GatewayModel] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]] else { return [] }
        return items.compactMap { ($0["id"] as? String).map { GatewayModel(id: $0, mode: nil) } }
    }

    // Pure + testable: parse an OpenAI images response into URLs or decoded bytes.
    // gpt-image-1 returns `b64_json` only; DALL-E / many gateway models return `url`.
    enum DecodedImage: Sendable, Equatable {
        case url(URL)
        case base64(Data)
    }

    static func decodeImages(from data: Data) throws -> [DecodedImage] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenAICompatGenerationError.decodeFailed
        }
        if let err = obj["error"] as? [String: Any], let message = err["message"] as? String {
            throw OpenAICompatGenerationError.api(message)
        }
        guard let items = obj["data"] as? [[String: Any]] else {
            throw OpenAICompatGenerationError.decodeFailed
        }
        var out: [DecodedImage] = []
        for item in items {
            if let urlStr = item["url"] as? String, let url = URL(string: urlStr) {
                out.append(.url(url))
            } else if let b64 = item["b64_json"] as? String, let bytes = Data(base64Encoded: b64) {
                out.append(.base64(bytes))
            }
        }
        if out.isEmpty { throw OpenAICompatGenerationError.emptyResponse }
        return out
    }
}

enum OpenAICompatGenerationError: LocalizedError {
    case httpError(status: Int, body: String)
    case api(String)
    case emptyResponse
    case decodeFailed

    var errorDescription: String? {
        switch self {
        case .httpError(let status, let body): "Image gateway error (\(status)): \(body.prefix(400))"
        case .api(let message): message
        case .emptyResponse: "The image gateway returned no images."
        case .decodeFailed: "Could not parse the image gateway response."
        }
    }
}
