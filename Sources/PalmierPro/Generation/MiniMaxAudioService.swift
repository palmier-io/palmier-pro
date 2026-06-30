import Foundation

struct MiniMaxAudioOutput: Sendable {
    let data: Data
    let fileExtension: String
}

enum MiniMaxAudioError: LocalizedError {
    case missingAPIKey
    case unsupportedModel(String)
    case unsupportedInput(String)
    case transport(String)
    case api(status: Int, message: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            "Set a MiniMax API key before generating."
        case .unsupportedModel(let model):
            "MiniMax cannot generate with model '\(model)'."
        case .unsupportedInput(let message):
            message
        case .transport(let message):
            message
        case .api(_, let message):
            message
        case .emptyResponse:
            "MiniMax returned no audio."
        }
    }
}

enum MiniMaxAudioService {
    static func canGenerate(model: AudioModelConfig) -> Bool {
        apiModelId(for: model) != nil
    }

    static func generate(model: AudioModelConfig, params: AudioGenerationParams) async throws -> MiniMaxAudioOutput {
        guard let key = AudioGenerationCredentialStore.load(provider: .minimax)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty
        else {
            throw MiniMaxAudioError.missingAPIKey
        }
        guard params.videoURL == nil else {
            throw MiniMaxAudioError.unsupportedInput("MiniMax music generation does not accept a video source.")
        }
        guard let apiModel = apiModelId(for: model) else {
            throw MiniMaxAudioError.unsupportedModel(model.id)
        }

        var request = URLRequest(url: MiniMaxAPIRegion.stored.musicGenerationURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let lyrics = params.lyrics?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        var body: [String: Any] = [
            "model": apiModel,
            "prompt": params.prompt,
            "stream": false,
            "output_format": "hex",
            "lyrics_optimizer": lyrics == nil && !params.instrumental,
            "is_instrumental": params.instrumental,
            "audio_setting": [
                "format": "mp3",
                "sample_rate": 44100,
                "bitrate": 256000,
            ],
        ]
        if let lyrics { body["lyrics"] = lyrics }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MiniMaxAudioError.transport("Non-HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.errorMessage(from: data) ?? "MiniMax HTTP \(http.statusCode)"
            throw MiniMaxAudioError.api(status: http.statusCode, message: message)
        }
        guard let output = try await Self.output(from: data) else {
            throw MiniMaxAudioError.emptyResponse
        }
        return output
    }

    static func apiModelId(for model: AudioModelConfig) -> String? {
        if let raw = MiniMaxModelId.raw(model.id) {
            return raw
        }
        let normalized = model.id.lowercased()
        let name = model.displayName.lowercased()
        guard normalized.contains("minimax") || name.contains("minimax") else { return nil }
        if normalized.contains("music-2.6-free") || normalized.contains("music-v2.6-free") {
            return "music-2.6-free"
        }
        if normalized.contains("music-2.6") || normalized.contains("music-v2.6") {
            return "music-2.6"
        }
        return model.category == .music ? "music-2.6" : nil
    }

    private static func output(from data: Data) async throws -> MiniMaxAudioOutput? {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let object else { return nil }
        if let message = baseResponseError(from: object) {
            throw MiniMaxAudioError.transport(message)
        }
        let payload = object["data"] as? [String: Any] ?? object
        if let urlString = payload["audio_url"] as? String,
           let url = URL(string: urlString) {
            let (downloaded, _) = try await URLSession.shared.data(from: url)
            return MiniMaxAudioOutput(data: downloaded, fileExtension: url.pathExtension.isEmpty ? "mp3" : url.pathExtension)
        }
        let hex = payload["audio"] as? String
            ?? payload["audio_file"] as? String
            ?? payload["audio_data"] as? String
            ?? payload["audio_hex"] as? String
        if let hex, let decoded = Data(hexEncoded: hex) {
            return MiniMaxAudioOutput(data: decoded, fileExtension: "mp3")
        }
        if let base64 = payload["audio_base64"] as? String,
           let decoded = Data(base64Encoded: base64) {
            return MiniMaxAudioOutput(data: decoded, fileExtension: "mp3")
        }
        return nil
    }

    private static func baseResponseError(from object: [String: Any]) -> String? {
        guard let base = object["base_resp"] as? [String: Any] else { return nil }
        let statusCode = base["status_code"] as? Int ?? 0
        guard statusCode != 0 else { return nil }
        let message = base["status_msg"] as? String ?? "MiniMax status \(statusCode)"
        return message
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8)
        }
        if let message = object["message"] as? String { return message }
        if let error = object["error"] as? [String: Any] {
            return error["message"] as? String ?? error["code"] as? String
        }
        return String(data: data, encoding: .utf8)
    }
}

private extension Data {
    init?(hexEncoded string: String) {
        let cleaned = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = Data(bytes)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
