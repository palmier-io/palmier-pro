import Foundation

struct VolcengineSpeechClient {
    let settings: VolcengineSpeechSettings
    var session: URLSession = .shared

    func transcribe(audioURL: URL, preferredLocale: Locale?) async throws -> TranscriptionResult {
        guard settings.hasAPIKey else {
            throw TranscriptionError.missingAPIKey("Volcengine Speech API key is not configured.")
        }
        guard settings.isAvailable else {
            throw TranscriptionError.analysisFailed("Volcengine Speech resource is not configured.")
        }

        let audioData = try Data(contentsOf: audioURL)
        let requestID = UUID().uuidString
        var request = URLRequest(url: settings.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(settings.apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(settings.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(audioData: audioData, preferredLocale: preferredLocale))

        Log.transcription.notice(
            "volcengine start bytes=\(audioData.count)",
            telemetry: "Volcengine transcription started",
            data: ["bytes": audioData.count, "resourceID": settings.resourceID]
        )
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.analysisFailed("Volcengine Speech returned a non-HTTP response.")
        }
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(http.statusCode) else {
            throw TranscriptionError.httpError(status: http.statusCode, body: bodyText)
        }
        if let status = http.value(forHTTPHeaderField: "X-Api-Status-Code"),
           status != "20000000" {
            let message = http.value(forHTTPHeaderField: "X-Api-Message") ?? bodyText
            throw TranscriptionError.analysisFailed("Volcengine Speech status \(status): \(message)")
        }

        let decoded = try Self.decode(data)
        Log.transcription.notice(
            "volcengine ok textChars=\(decoded.text.count) words=\(decoded.words.count)",
            telemetry: "Volcengine transcription finished",
            data: ["textChars": decoded.text.count, "words": decoded.words.count, "segments": decoded.segments.count]
        )
        return decoded
    }

    private func body(audioData: Data, preferredLocale: Locale?) -> [String: Any] {
        var audio: [String: Any] = [
            "data": audioData.base64EncodedString(),
            "format": "wav",
            "rate": 16_000,
            "channel": 1,
            "bits": 16,
        ]
        if let preferredLocale {
            audio["language"] = preferredLocale.identifier(.bcp47)
        }
        return [
            "user": ["uid": "PalmierPro-\(Host.current().localizedName ?? "mac")"],
            "audio": audio,
            "request": [
                "model_name": "bigmodel",
                "enable_punc": true,
                "enable_itn": true,
                "enable_ddc": false,
                "enable_speaker_info": false,
                "show_utterances": true,
            ],
        ]
    }

    private static func decode(_ data: Data) throws -> TranscriptionResult {
        let root = try JSONDecoder().decode(VolcengineSpeechResponse.self, from: data)
        if let code = root.code, !["0", "20000000"].contains(code) {
            throw TranscriptionError.analysisFailed("Volcengine Speech code \(code): \(root.message ?? "")")
        }
        let payloadText = root.result?.text ?? root.text
        let utterances = root.result?.utterances ?? root.utterances ?? []

        var words: [TranscriptionWord] = []
        var segments: [TranscriptionSegment] = []
        for utterance in utterances {
            let text = (utterance.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let start = seconds(fromMilliseconds: utterance.startTime)
            let end = seconds(fromMilliseconds: utterance.endTime)
            if !text.isEmpty, let start, let end, end > start {
                segments.append(TranscriptionSegment(text: text, start: start, end: end))
            }
            for word in utterance.words ?? [] {
                let text = (word.text ?? word.word ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                words.append(TranscriptionWord(
                    text: text,
                    start: seconds(fromMilliseconds: word.startTime),
                    end: seconds(fromMilliseconds: word.endTime)
                ))
            }
        }

        if segments.isEmpty, let text = payloadText?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !text.isEmpty {
            let start = words.compactMap(\.start).min() ?? 0
            let end = words.compactMap(\.end).max() ?? max(start + 1, 1)
            segments.append(TranscriptionSegment(text: text, start: start, end: end))
        }
        let text = payloadText?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            ?? segments.map(\.text).joined(separator: " ")
        guard !text.isEmpty || !segments.isEmpty || !words.isEmpty else {
            throw TranscriptionError.decodeFailed
        }
        return TranscriptionResult(text: text, language: nil, words: words, segments: segments)
    }

    private static func seconds(fromMilliseconds value: Int?) -> Double? {
        value.map { Double($0) / 1000.0 }
    }
}

private struct VolcengineSpeechResponse: Decodable {
    var code: String?
    var message: String?
    var text: String?
    var utterances: [VolcengineSpeechUtterance]?
    var result: VolcengineSpeechPayload?

    private enum CodingKeys: String, CodingKey {
        case code, message, text, utterances, result
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = Self.decodeString(c, .code)
        message = Self.decodeString(c, .message)
        text = try? c.decode(String.self, forKey: .text)
        utterances = try? c.decode([VolcengineSpeechUtterance].self, forKey: .utterances)
        result = try? c.decode(VolcengineSpeechPayload.self, forKey: .result)
    }

    static func decodeString<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> String? {
        if let value = try? c.decode(String.self, forKey: key) { return value }
        if let value = try? c.decode(Int.self, forKey: key) { return String(value) }
        return nil
    }
}

private struct VolcengineSpeechPayload: Decodable {
    var text: String?
    var utterances: [VolcengineSpeechUtterance]?
}

private struct VolcengineSpeechUtterance: Decodable {
    var text: String?
    var startTime: Int?
    var endTime: Int?
    var words: [VolcengineSpeechWord]?

    private enum CodingKeys: String, CodingKey {
        case text, words
        case startTime = "start_time"
        case endTime = "end_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try? c.decode(String.self, forKey: .text)
        startTime = Self.decodeMilliseconds(c, .startTime)
        endTime = Self.decodeMilliseconds(c, .endTime)
        words = try? c.decode([VolcengineSpeechWord].self, forKey: .words)
    }

    static func decodeMilliseconds<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) -> Int? {
        if let value = try? c.decode(Int.self, forKey: key) { return value }
        if let value = try? c.decode(Double.self, forKey: key) { return Int(value.rounded()) }
        if let value = try? c.decode(String.self, forKey: key),
           let number = Double(value),
           number.isFinite {
            return Int(number.rounded())
        }
        return nil
    }
}

private struct VolcengineSpeechWord: Decodable {
    var text: String?
    var word: String?
    var startTime: Int?
    var endTime: Int?

    private enum CodingKeys: String, CodingKey {
        case text, word
        case startTime = "start_time"
        case endTime = "end_time"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try? c.decode(String.self, forKey: .text)
        word = try? c.decode(String.self, forKey: .word)
        startTime = VolcengineSpeechUtterance.decodeMilliseconds(c, .startTime)
        endTime = VolcengineSpeechUtterance.decodeMilliseconds(c, .endTime)
    }
}
