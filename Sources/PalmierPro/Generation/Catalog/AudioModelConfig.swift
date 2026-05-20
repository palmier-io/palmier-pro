import Foundation

struct AudioGenerationParams: Encodable, Sendable {
    let prompt: String
    let voice: String?
    let lyrics: String?
    let styleInstructions: String?
    let instrumental: Bool
    let durationSeconds: Int?

    enum CodingKeys: String, CodingKey {
        case kind, prompt, voice, lyrics, styleInstructions, instrumental, durationSeconds
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("audio", forKey: .kind)
        try c.encode(prompt, forKey: .prompt)
        try c.encodeIfPresent(voice, forKey: .voice)
        try c.encodeIfPresent(lyrics, forKey: .lyrics)
        try c.encodeIfPresent(styleInstructions, forKey: .styleInstructions)
        try c.encode(instrumental, forKey: .instrumental)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
    }
}

struct AudioModelConfig: Identifiable, Sendable {
    enum Category: Sendable {
        case tts
        case music
    }

    enum Pricing: Sendable {
        case perThousandChars(Double)
        case perSecond(Double)
        case flat(Double)
        case unknown
    }

    @MainActor
    static var allModels: [AudioModelConfig] { ModelCatalog.shared.audio }

    let entry: CatalogEntry
    let caps: AudioCaps

    var id: String { entry.id }
    var displayName: String { entry.displayName }

    var category: Category { caps.category == "music" ? .music : .tts }
    var voices: [String]? { caps.voices }
    var defaultVoice: String? { caps.defaultVoice }
    var supportsLyrics: Bool { caps.supportsLyrics }
    var supportsInstrumental: Bool { caps.supportsInstrumental }
    var supportsStyleInstructions: Bool { caps.supportsStyleInstructions }
    var durations: [Int]? { caps.durations }
    var minPromptLength: Int { caps.minPromptLength }

    var pricing: Pricing {
        switch entry.audioPricing {
        case .perThousandChars(let rate): return .perThousandChars(rate)
        case .perSecond(let rate): return .perSecond(rate)
        case .flat(let price): return .flat(price)
        case .none: return .unknown
        }
    }

    func validate(params: AudioGenerationParams) -> String? {
        let promptLen = params.prompt.trimmingCharacters(in: .whitespaces).count
        if promptLen < minPromptLength {
            return "\(displayName) requires prompt ≥ \(minPromptLength) characters (got \(promptLen))."
        }
        if let allowed = voices, let v = params.voice, !v.isEmpty, !allowed.contains(v) {
            let shown = Array(allowed.prefix(6)) + (allowed.count > 6 ? ["…"] : [])
            return unsupportedValue(model: displayName, field: "voice", value: v, allowed: shown)
        }
        if let allowed = durations, let d = params.durationSeconds, !allowed.contains(d) {
            return unsupportedValue(
                model: displayName, field: "duration",
                value: "\(d)s", allowed: allowed.map { "\($0)s" }
            )
        }
        return nil
    }
}
