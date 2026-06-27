import Foundation

extension Notification.Name {
    static let twelveLabsAPIKeyChanged = Notification.Name("twelveLabsAPIKeyChanged")
}

enum TwelveLabsKeychain {
    private static let account = "twelvelabs-api-key"

    static func save(_ key: String) {
        KeychainStore.save(key, account: account)
        NotificationCenter.default.post(name: .twelveLabsAPIKeyChanged, object: nil)
    }

    static func load() -> String? {
        #if DEBUG
        if let env = ProcessInfo.processInfo.environment["TWELVELABS_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty {
            return env
        }
        #endif
        return KeychainStore.load(account: account)
    }

    static func delete() {
        KeychainStore.delete(account: account)
        NotificationCenter.default.post(name: .twelveLabsAPIKeyChanged, object: nil)
    }
}

enum TwelveLabsClientError: LocalizedError {
    case missingAPIKey
    case httpError(status: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No TwelveLabs API key is set. Add one in Settings → Agent."
        case .httpError(let status, let body): "TwelveLabs API error (\(status)): \(body.prefix(500))"
        case .decoding(let msg): "TwelveLabs response error: \(msg)"
        }
    }
}

/// TwelveLabs Pegasus video understanding over the v1.3 REST API (no official Swift SDK).
struct TwelveLabsClient: Sendable {
    let apiKey: String

    private static let baseURL = URL(string: "https://api.twelvelabs.io/v1.3")!
    private static let pegasusModel = "pegasus1.5"

    /// Uploads a local video file as a TwelveLabs asset, then asks Pegasus the prompt about it.
    func understand(videoURL: URL, prompt: String) async throws -> String {
        let assetID = try await uploadAsset(fileURL: videoURL)
        return try await analyze(assetID: assetID, prompt: prompt)
    }

    private func uploadAsset(fileURL: URL) async throws -> String {
        guard !apiKey.isEmpty else { throw TwelveLabsClientError.missingAPIKey }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("assets"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: fileURL)
        }.value
        var body = Data()
        body.appendFormField("method", value: "direct", boundary: boundary)
        body.appendFileField(
            "file", filename: fileURL.lastPathComponent,
            mimeType: Self.mimeType(for: fileURL), data: fileData, boundary: boundary
        )
        body.appendBoundaryTerminator(boundary)
        request.httpBody = body

        let json = try await send(request)
        guard let id = (json["_id"] ?? json["id"]) as? String, !id.isEmpty else {
            throw TwelveLabsClientError.decoding("asset response missing _id")
        }
        return id
    }

    private func analyze(assetID: String, prompt: String) async throws -> String {
        guard !apiKey.isEmpty else { throw TwelveLabsClientError.missingAPIKey }

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("analyze"))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "video": ["type": "asset_id", "asset_id": assetID],
            "prompt": prompt,
            "model_name": Self.pegasusModel,
            "stream": false,
        ])

        let json = try await send(request)
        guard let text = json["data"] as? String else {
            throw TwelveLabsClientError.decoding("analyze response missing data")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw TwelveLabsClientError.httpError(
                status: http.statusCode,
                body: String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TwelveLabsClientError.decoding("response was not a JSON object")
        }
        return json
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mov": "video/quicktime"
        case "m4v": "video/x-m4v"
        case "webm": "video/webm"
        default: "video/mp4"
        }
    }
}

private extension Data {
    mutating func appendFormField(_ name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }

    mutating func appendFileField(
        _ name: String, filename: String, mimeType: String, data: Data, boundary: String
    ) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendBoundaryTerminator(_ boundary: String) {
        append("--\(boundary)--\r\n".data(using: .utf8)!)
    }
}
