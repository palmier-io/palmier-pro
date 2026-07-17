// Process-wide decoder-bias bridge from the glossary to the transcription engines.
// Project-aware call sites publish hotwords before transcribing (GlossaryStore.applyBias());
// engines read them when (re)building a recognizer, and TranscriptCache salts keys with the
// fingerprint so a changed hotword set forces a fresh transcription. §4
import Foundation
import Synchronization

enum TranscriptionBias {
    private struct State: Sendable {
        var hotwords: [String] = []
        var fingerprint: String?
    }

    private static let state = Mutex(State())

    /// Comma-separated hotword list for sherpa's qwen3_asr.hotwords; nil when no bias is active.
    static var hotwordsCSV: String? {
        state.withLock { $0.hotwords.isEmpty ? nil : $0.hotwords.joined(separator: ",") }
    }

    /// Cache-key salt; nil when no bias is active so unbiased cache keys stay byte-identical.
    static var fingerprint: String? {
        state.withLock { $0.fingerprint }
    }

    static func update(hotwords: [String], fingerprint: String) {
        state.withLock {
            $0.hotwords = hotwords
            $0.fingerprint = hotwords.isEmpty ? nil : fingerprint
        }
    }
}
