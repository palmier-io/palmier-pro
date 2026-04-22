import Foundation
import FalClient

struct AudioGenerationParams: Sendable {
    let prompt: String
    let voice: String?
    let lyrics: String?
    let styleInstructions: String?
    let instrumental: Bool
    let durationSeconds: Int?
}

struct AudioModelConfig: Identifiable, Sendable {
    enum Category: Sendable {
        case tts
        case music
    }

    enum Pricing: Sendable {
        /// USD per 1000 characters of prompt text (TTS).
        case perThousandChars(Double)
        /// USD per output second (music with duration param).
        case perSecond(Double)
        /// USD per generation, duration-agnostic.
        case flat(Double)
        /// Price unknown — estimator returns nil.
        case unknown
    }

    let id: String
    let displayName: String
    let baseEndpoint: String
    let category: Category
    let voices: [String]?
    let defaultVoice: String?
    let supportsLyrics: Bool
    let supportsInstrumental: Bool
    let supportsStyleInstructions: Bool
    let durations: [Int]?
    let minPromptLength: Int
    let pricing: Pricing
    let buildFalInput: @Sendable (_ params: AudioGenerationParams) -> Payload

    init(
        id: String, displayName: String, baseEndpoint: String, category: Category,
        voices: [String]? = nil, defaultVoice: String? = nil,
        supportsLyrics: Bool = false, supportsInstrumental: Bool = false,
        supportsStyleInstructions: Bool = false, durations: [Int]? = nil,
        minPromptLength: Int = 1,
        pricing: Pricing = .unknown,
        buildFalInput: @escaping @Sendable (AudioGenerationParams) -> Payload
    ) {
        self.id = id; self.displayName = displayName; self.baseEndpoint = baseEndpoint
        self.category = category
        self.voices = voices; self.defaultVoice = defaultVoice
        self.supportsLyrics = supportsLyrics; self.supportsInstrumental = supportsInstrumental
        self.supportsStyleInstructions = supportsStyleInstructions
        self.durations = durations
        self.minPromptLength = minPromptLength
        self.pricing = pricing
        self.buildFalInput = buildFalInput
    }

    func buildInput(params: AudioGenerationParams) -> Payload {
        buildFalInput(params)
    }
}

extension AudioModelConfig {
    static let elevenLabsVoices = [
        "Rachel", "Aria", "Roger", "Sarah", "Laura", "Charlie", "George", "Callum",
        "River", "Liam", "Charlotte", "Alice", "Matilda", "Will", "Jessica", "Eric",
        "Chris", "Brian", "Daniel", "Lily", "Bill",
    ]

    static let geminiVoices = [
        "Kore", "Achernar", "Achird", "Algenib", "Algieba", "Alnilam", "Aoede",
        "Autonoe", "Callirrhoe", "Charon", "Despina", "Enceladus", "Erinome",
        "Fenrir", "Gacrux", "Iapetus", "Laomedeia", "Leda", "Orus", "Pulcherrima",
        "Puck", "Rasalgethi", "Sadachbia", "Sadaltager", "Schedar", "Sulafat",
        "Umbriel", "Vindemiatrix", "Zephyr", "Zubenelgenubi",
    ]

    static let elevenLabsTTSv3 = AudioModelConfig(
        id: "elevenlabs-tts-v3",
        displayName: "ElevenLabs v3 TTS",
        baseEndpoint: "fal-ai/elevenlabs/tts/eleven-v3",
        category: .tts,
        voices: elevenLabsVoices, defaultVoice: "Rachel",
        pricing: .perThousandChars(0.10),
        buildFalInput: { p in
            var d: [String: Payload] = ["text": .string(p.prompt)]
            if let v = p.voice, !v.isEmpty { d["voice"] = .string(v) }
            return .dict(d)
        }
    )

    static let geminiFlashTTS = AudioModelConfig(
        id: "gemini-3.1-flash-tts",
        displayName: "Gemini 3.1 Flash TTS",
        baseEndpoint: "fal-ai/gemini-3.1-flash-tts",
        category: .tts,
        voices: geminiVoices, defaultVoice: "Kore",
        supportsStyleInstructions: true,
        pricing: .perThousandChars(0.03),
        buildFalInput: { p in
            var d: [String: Payload] = ["prompt": .string(p.prompt)]
            if let v = p.voice, !v.isEmpty { d["voice"] = .string(v) }
            if let s = p.styleInstructions, !s.isEmpty {
                d["style_instructions"] = .string(s)
            }
            return .dict(d)
        }
    )

    static let minimaxMusicV26 = AudioModelConfig(
        id: "minimax-music-v2.6",
        displayName: "MiniMax Music 2.6",
        baseEndpoint: "fal-ai/minimax-music/v2.6",
        category: .music,
        supportsLyrics: true, supportsInstrumental: true,
        minPromptLength: 10,
        pricing: .flat(0.03),
        buildFalInput: { p in
            var d: [String: Payload] = ["prompt": .string(p.prompt)]
            d["is_instrumental"] = .bool(p.instrumental)
            let hasLyrics = !(p.lyrics?.isEmpty ?? true)
            if hasLyrics, let l = p.lyrics { d["lyrics"] = .string(l) }
            // MiniMax rejects non-instrumental requests without lyrics; opt into auto-lyrics instead.
            if !p.instrumental && !hasLyrics {
                d["lyrics_optimizer"] = .bool(true)
            }
            return .dict(d)
        }
    )

    static let elevenLabsMusic = AudioModelConfig(
        id: "elevenlabs-music",
        displayName: "ElevenLabs Music",
        baseEndpoint: "fal-ai/elevenlabs/music",
        category: .music,
        supportsInstrumental: true,
        durations: [15, 30, 60, 90, 120, 180],
        pricing: .perSecond(0.002),
        buildFalInput: { p in
            var d: [String: Payload] = ["prompt": .string(p.prompt)]
            if let secs = p.durationSeconds { d["music_length_ms"] = .int(secs * 1000) }
            d["force_instrumental"] = .bool(p.instrumental)
            return .dict(d)
        }
    )

    static let allModels: [AudioModelConfig] = [
        elevenLabsTTSv3, geminiFlashTTS, minimaxMusicV26, elevenLabsMusic,
    ]
}
