// Selects which on-device ASR engine backs local transcription. Qwen3-ASR is the default:
// unlike Apple Speech (locked to one locale chosen from SYSTEM language settings, not audio),
// it transcribes code-switched speech natively; a parallel Whisper pass anchors word timing.
import Foundation

enum LocalSpeechEngine: String, CaseIterable, Identifiable, Sendable {
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
        case .qwen3: "Highest accuracy; 30+ languages, 20+ Chinese dialects, mixed-language speech. ~4 GB of downloads. Word timing aligned via a parallel Whisper pass."
        case .whisper: "Word-level timestamps, ~100 languages. ~1 GB download."
        case .apple: "System engine. Single language per file, chosen from your macOS language settings."
        }
    }

    /// Distinguishes cache entries across engines so switching engines re-transcribes.
    var cacheTag: String? {
        switch self {
        case .apple: nil  // preserves pre-existing cache entries
        case .qwen3: "qw4"  // v4: forced-language rescue pass, pinyin anchors, silent punctuation
        case .whisper: "wk1"
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
