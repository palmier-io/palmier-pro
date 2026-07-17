// Materialisation — apply a glossary corrector to a raw TranscriptionResult at READ time.
// Never called at store time: the cached raw ASR JSON on disk always stays raw. refs feature/glossary

import Foundation

extension TranscriptionResult {
    /// Returns a corrected copy: variants replaced with canonicals in `text`, every segment's text,
    /// and every word's text. Timings are untouched (text-only substitution). Raw self is unchanged.
    func applyingGlossary(_ corrector: GlossaryCorrector) -> TranscriptionResult {
        guard !corrector.isEmpty else { return self }

        // Words: first collapse whole-word spans (multi-token variants), then correct within tokens
        // (a single CJK token that holds the whole phrase). Emptied span tail keeps karaoke sane.
        let spanned = corrector.correctWordSpans(words.map(\.text))
        let correctedWords: [TranscriptionWord] = zip(words, spanned).map { word, text in
            TranscriptionWord(
                text: text.isEmpty ? text : corrector.correct(text),
                start: word.start,
                end: word.end,
                speaker: word.speaker
            )
        }

        return TranscriptionResult(
            text: corrector.correct(text),
            language: language,
            words: correctedWords,
            segments: segments.map {
                TranscriptionSegment(text: corrector.correct($0.text), start: $0.start, end: $0.end, speaker: $0.speaker)
            }
        )
    }
}
