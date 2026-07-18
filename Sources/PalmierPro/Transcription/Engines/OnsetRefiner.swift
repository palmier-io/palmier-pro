// Onset refinement — rolls a word's start back toward its true acoustic onset when the word
// begins a speech run after a silence gap, so captions lead the syllable instead of inheriting a
// chunk/anchor-quantized start (the ~1.8s lag on the first word after a pause). Pure over 16kHz
// mono PCM; shared by the Qwen3 and Whisper engines so the transcript itself improves. refs BUG-3
import Foundation

enum OnsetRefiner {
    /// A word qualifies for refinement when the silence before it exceeds this (seconds).
    static let gapThreshold = 0.3
    /// Never roll a start back further than this before its current position (seconds). Covers the
    /// long chunk-quantization lag after a pause (real cases exceed 1.7s); still bounded by the
    /// previous word's end and the energy rising edge, so a larger cap only helps genuine silence gaps.
    static let maxRollback = 2.5
    /// Land this many frames early so the caption leads the consonant rather than clipping it.
    static let leadFrames = 2.5

    /// Returns `words` with qualifying starts rolled back to the energy rising edge. `samples` is
    /// 16kHz mono; word times are in seconds. Word order and every other field are preserved.
    static func refine(
        words: [TranscriptionWord],
        samples: [Float],
        sampleRate: Int = EngineAudio.sampleRate,
        fps: Int
    ) -> [TranscriptionWord] {
        guard !samples.isEmpty else { return words }
        var out = words
        let lead = leadFrames / Double(max(1, fps))
        var previousEnd: Double? = nil

        for index in out.indices {
            let word = out[index]
            guard let start = word.start, let end = word.end, end > start, isSpeech(word.text) else {
                continue
            }
            defer { if let e = out[index].end { previousEnd = max(previousEnd ?? 0, e) } }

            let gap = previousEnd.map { start - $0 } ?? start
            guard gap > gapThreshold else { continue }

            let lowerBound = max(previousEnd ?? 0, start - maxRollback)
            guard let onset = risingEdge(samples: samples, sampleRate: sampleRate, from: lowerBound, to: start) else {
                continue
            }
            let refined = max(lowerBound, min(start, onset - lead))
            guard refined < start else { continue }   // only ever lead in, never push a start later
            out[index] = TranscriptionWord(
                text: word.text, start: refined, end: end, speaker: word.speaker, aligned: word.aligned)
        }
        return out
    }

    /// Speech-attack window: floor→sustained must complete within this (seconds), else it is a slow
    /// swell (e.g. a music fade-in), not a voice onset.
    private static let attackWindow = 0.25
    /// A genuine syllable holds for at least this (seconds) after its attack; a transient (isolated
    /// click) drops back to the floor immediately and is rejected.
    private static let minSustain = 0.05

    /// First time (seconds) in [from, to) of a genuine speech attack: a near-silent frame followed by a
    /// fast rise (within `attackWindow`) to sustained energy that then holds for at least `minSustain`.
    /// Returns nil when the region has no such attack — uniformly quiet, uniformly loud, a slow fade-in
    /// whose energy climbs over seconds, or an isolated click that spikes and immediately decays.
    private static func risingEdge(samples: [Float], sampleRate: Int, from: Double, to: Double) -> Double? {
        let lo = max(0, Int(from * Double(sampleRate)))
        let hi = min(samples.count, Int(to * Double(sampleRate)))
        let window = max(1, sampleRate / 100)   // 10ms frames
        guard hi - lo >= window * 2 else { return nil }

        var energies: [Float] = []
        energies.reserveCapacity((hi - lo) / window)
        var i = lo
        while i + window <= hi {
            var sum: Float = 0
            for s in samples[i..<(i + window)] { sum += s * s }
            energies.append(sum / Float(window))
            i += window
        }
        guard energies.count >= 2, let peak = energies.max(), peak > 0 else { return nil }

        let floor = energies.min() ?? 0
        // Require a real rise over the floor; a uniformly loud region (no gap edge) has none.
        guard peak > floor + 1e-6, peak > floor * 4 else { return nil }
        let range = peak - floor
        let threshold = floor + range * 0.15
        let sustainedLevel = floor + range * 0.5
        let silenceBar = floor + range * 0.1
        let frameDur = Double(window) / Double(sampleRate)
        let attackFrames = max(1, Int((attackWindow / frameDur).rounded()))
        let sustainFrames = max(1, Int((minSustain / frameDur).rounded()))

        // Scan silence frames in ascending order; the first that opens a valid attack gives the onset.
        for j in energies.indices where energies[j] <= silenceBar {
            guard let sustainedIdx = (j + 1..<energies.count).first(where: { energies[$0] >= sustainedLevel })
            else { break }                              // no sustained energy after any later silence either
            guard sustainedIdx - j <= attackFrames else { continue }   // slow swell (fade-in) — not an attack
            let holdEnd = min(energies.count, sustainedIdx + sustainFrames)
            guard (sustainedIdx..<holdEnd).allSatisfy({ energies[$0] >= threshold }) else { continue }  // transient click
            let onset = (j..<sustainedIdx).first(where: { energies[$0] > threshold }) ?? sustainedIdx
            return Double(lo + onset * window) / Double(sampleRate)
        }
        return nil
    }

    /// A word carries speech (letters/digits/CJK) rather than being pure punctuation.
    private static func isSpeech(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) || (0x2E80...0x9FFF).contains(Int(scalar.value))
        }
    }
}
