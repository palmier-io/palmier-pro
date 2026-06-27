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
    case fileTooLarge(bytes: Int, limit: Int)
    case httpError(status: Int, body: String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey: "No TwelveLabs API key is set. Add one in Settings → Agent."
        case .fileTooLarge(let bytes, let limit):
            let mb = { (b: Int) in String(format: "%.0f", Double(b) / 1_048_576) }
            return "Video is \(mb(bytes)) MB, but TwelveLabs direct upload supports up to \(mb(limit)) MB. "
                + "Export or trim a smaller clip and retry. (Larger files need TwelveLabs' multipart upload, which isn't wired up yet.)"
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
    /// Large uploads and whole-clip Pegasus analysis routinely run past URLSession's
    /// default 60s request timeout, so give both a generous ceiling.
    private static let requestTimeout: TimeInterval = 300
    /// TwelveLabs caps direct local-file uploads (`method=direct`) at 200 MB; larger files
    /// require the separate multipart/chunked upload flow. Guard so callers get a clear
    /// message instead of an opaque API failure on full-resolution source clips.
    private static let maxDirectUploadBytes = 200 * 1_048_576

    /// Uploads a local video file as a TwelveLabs asset, then asks Pegasus the prompt about it.
    func understand(videoURL: URL, prompt: String) async throws -> String {
        let assetID = try await uploadAsset(fileURL: videoURL)
        return try await analyze(assetID: assetID, prompt: prompt)
    }

    private func uploadAsset(fileURL: URL) async throws -> String {
        guard !apiKey.isEmpty else { throw TwelveLabsClientError.missingAPIKey }

        if let bytes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
           bytes > Self.maxDirectUploadBytes {
            throw TwelveLabsClientError.fileTooLarge(bytes: bytes, limit: Self.maxDirectUploadBytes)
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: Self.baseURL.appendingPathComponent("assets"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // Stream the multipart body to a temp file so a multi-GB source clip is never
        // held in memory all at once; upload(fromFile:) then streams it from disk.
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tl-upload-\(UUID().uuidString).multipart")
        try Self.writeMultipartBody(
            to: bodyURL, fileURL: fileURL,
            mimeType: Self.mimeType(for: fileURL), boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: bodyURL)
        let json = try Self.decodeJSON(data, response)
        guard let id = (json["_id"] ?? json["id"]) as? String, !id.isEmpty else {
            throw TwelveLabsClientError.decoding("asset response missing _id")
        }
        return id
    }

    /// Writes the `method=direct` field and the file part to `bodyURL`, streaming the
    /// source file in 1 MiB chunks so it is never fully resident in memory.
    private static func writeMultipartBody(
        to bodyURL: URL, fileURL: URL, mimeType: String, boundary: String
    ) throws {
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: bodyURL)
        defer { try? out.close() }

        var header = Data()
        header.appendFormField("method", value: "direct", boundary: boundary)
        header.append("--\(boundary)\r\n".data(using: .utf8)!)
        header.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n"
                .data(using: .utf8)!
        )
        header.append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        try out.write(contentsOf: header)

        let input = try FileHandle(forReadingFrom: fileURL)
        defer { try? input.close() }
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            try out.write(contentsOf: chunk)
        }

        var footer = Data()
        footer.append("\r\n".data(using: .utf8)!)
        footer.appendBoundaryTerminator(boundary)
        try out.write(contentsOf: footer)
    }

    private func analyze(assetID: String, prompt: String) async throws -> String {
        guard !apiKey.isEmpty else { throw TwelveLabsClientError.missingAPIKey }

        var request = URLRequest(url: Self.baseURL.appendingPathComponent("analyze"))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
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
        return try Self.decodeJSON(data, response)
    }

    private static func decodeJSON(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
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

    mutating func appendBoundaryTerminator(_ boundary: String) {
        append("--\(boundary)--\r\n".data(using: .utf8)!)
    }
}
