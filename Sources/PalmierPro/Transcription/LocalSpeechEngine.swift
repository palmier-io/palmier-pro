// Selects which on-device ASR engine backs local transcription. SenseVoice is the default:
// unlike Apple Speech (locked to one locale chosen from SYSTEM language settings, not audio),
// it transcribes code-switched zh/en/ja/ko/yue natively. Whisper adds word-precise timing.
import Foundation

enum LocalSpeechEngine: String, CaseIterable, Identifiable, Sendable {
    case senseVoice
    case whisper
    case apple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .senseVoice: "SenseVoice (multilingual)"
        case .whisper: "Whisper (word timing)"
        case .apple: "Apple Speech"
        }
    }

    var detail: String {
        switch self {
        case .senseVoice: "Best for mixed-language speech (Chinese, English, Japanese, Korean, Cantonese). ~160 MB download."
        case .whisper: "Best word-level timestamps, ~100 languages. ~1 GB download, slower."
        case .apple: "System engine. Single language per file, chosen from your macOS language settings."
        }
    }

    /// Distinguishes cache entries across engines so switching engines re-transcribes.
    var cacheTag: String? {
        switch self {
        case .apple: nil  // preserves pre-existing cache entries
        case .senseVoice: "sv1"
        case .whisper: "wk1"
        }
    }

    private static let defaultsKey = "localSpeechEngine"

    static var current: LocalSpeechEngine {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(LocalSpeechEngine.init(rawValue:)) ?? .senseVoice
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }
}
