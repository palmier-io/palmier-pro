// Selects which on-device ASR engine backs local transcription. Qwen3-ASR is the default:
// unlike Apple Speech (locked to one locale chosen from SYSTEM language settings, not audio),
// it transcribes code-switched speech natively; a parallel Whisper pass anchors word timing.
import Foundation

enum LocalSpeechEngine: String, CaseIterable, Identifiable, Sendable, Codable {
    case qwen3
    case whisper
    case apple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .qwen3: "Qwen3-ASR (best quality)"
        case .whisper: "Whisper (fastest)"
        case .apple: "Apple Speech"
        }
    }

    var detail: String {
        switch self {
        case .qwen3: "Highest accuracy; 30+ languages, 20+ Chinese dialects, mixed-language speech. ~840 MB model plus a shared ~1.5 GB Whisper pass for word timing (~2.3 GB on first use)."
        case .whisper: "Word-level timestamps, ~100 languages. ~1.5 GB download."
        case .apple: "System engine. Single language per file, chosen from your macOS language settings."
        }
    }

    /// Stable model identifier surfaced to agents in transcription responses.
    var modelId: String {
        switch self {
        case .qwen3: "qwen3-asr-0.6B-int8"
        case .whisper: "whisper-large-v3_turbo"
        case .apple: "apple-speech"
        }
    }

    /// Distinguishes cache entries across engines so switching engines re-transcribes.
    var cacheTag: String? {
        switch self {
        case .apple: nil  // preserves pre-existing cache entries
        case .qwen3: "qw6"  // v6: acoustic onset refinement on first-after-pause words
        case .whisper: "wk2"  // v2: acoustic onset refinement
        }
    }

    private static let defaultsKey = "localSpeechEngine"

    static var current: LocalSpeechEngine {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(LocalSpeechEngine.init(rawValue:)) ?? .qwen3
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}
