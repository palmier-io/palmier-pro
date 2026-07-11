import Foundation

struct AudioGenerationParams: Encodable, Sendable {
    let prompt: String
    let voice: String?
    let lyrics: String?
    let styleInstructions: String?
    let instrumental: Bool
    let durationSeconds: Int?
    var videoURL: String? = nil
    var sourceURL: String? = nil
    var targetLanguage: String? = nil

    enum CodingKeys: String, CodingKey {
        case kind, prompt, voice, lyrics, styleInstructions, instrumental, durationSeconds
        case videoURL, sourceURL, targetLanguage
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
        try c.encodeIfPresent(videoURL, forKey: .videoURL)
        try c.encodeIfPresent(sourceURL, forKey: .sourceURL)
        try c.encodeIfPresent(targetLanguage, forKey: .targetLanguage)
    }
}

struct AudioModelConfig: Identifiable, Sendable {
    enum Category: String, Sendable, Hashable, CaseIterable {
        case tts
        case music
        case sfx
        case cleanup
        case dubbing

        var label: String {
            switch self {
            case .tts: "Speech"
            case .music: "Music"
            case .sfx: "Sound Effects"
            case .cleanup: "Voice Cleanup"
            case .dubbing: "Dubbing"
            }
        }
    }

    enum Input: String, Sendable, Hashable {
        case text
        case audio
        case video
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
    var paidOnly: Bool { entry.paidOnly }

    var category: Category {
        Category(rawValue: caps.category) ?? .tts
    }
    var voices: [String]? { caps.voices }
    var defaultVoice: String? { caps.defaultVoice }
    var supportsLyrics: Bool { caps.supportsLyrics }
    var supportsInstrumental: Bool { caps.supportsInstrumental }
    var supportsStyleInstructions: Bool { caps.supportsStyleInstructions }
    var durations: [Int]? { caps.durations }
    var minPromptLength: Int { caps.minPromptLength }

    var inputs: [Input] { (caps.inputs ?? ["text"]).compactMap(Input.init(rawValue:)) }
    var promptLabel: String { caps.promptLabel ?? "Describe the sound" }
    var minSeconds: Int { caps.minSeconds ?? 1 }
    var maxSeconds: Int { caps.maxSeconds ?? 600 }
    var targetLanguages: [String]? { caps.targetLanguages }
    var defaultTargetLanguage: String? { caps.defaultTargetLanguage }
    var acceptsSourceMedia: Bool { inputs.contains(.audio) || inputs.contains(.video) }
    var usesSourceURL: Bool { category == .cleanup || category == .dubbing }

    func acceptsSource(_ type: ClipType) -> Bool {
        switch type {
        case .audio: inputs.contains(.audio)
        case .video: inputs.contains(.video)
        case .image, .text, .lottie, .sequence: false
        }
    }

    static func languageName(_ code: String, locale: Locale = .current) -> String {
        guard !code.isEmpty else { return "Target Language" }
        return locale.localizedString(forLanguageCode: code)?.capitalized
            ?? code.uppercased()
    }

    func validate(spanSeconds: Double) -> String? {
        let s = Int(spanSeconds.rounded())
        if s < minSeconds {
            return "\(displayName) needs at least \(minSeconds)s of source media (selection is \(s)s)."
        }
        if s > maxSeconds {
            return "\(displayName) accepts at most \(maxSeconds)s of source media (selection is \(s)s)."
        }
        return nil
    }

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
        if inputs.contains(.text), promptLen < minPromptLength {
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
        if let allowed = targetLanguages {
            guard let language = params.targetLanguage, !language.isEmpty else {
                return "Choose a target language."
            }
            if !allowed.contains(language) {
                return unsupportedValue(
                    model: displayName,
                    field: "target language",
                    value: language,
                    allowed: allowed
                )
            }
        }
        return nil
    }
}
