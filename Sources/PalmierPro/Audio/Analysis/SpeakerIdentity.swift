import AVFoundation
import SpeechVAD

/// Identifies voices across files so the same speaker gets the same label everywhere.
enum SpeakerIdentity {
    static let cache = DiskCache(named: "SpeakerVoices")

    struct Turn {
        let speaker: String
        let start: Double
        let end: Double
    }

    /// Merges consecutive same-speaker words (gaps under 1 s) into turns.
    static func turns(from transcript: TranscriptionResult) -> [Turn] {
        var turns: [Turn] = []
        for word in transcript.words {
            guard let speaker = word.speaker, let start = word.start, let end = word.end else { continue }
            if let last = turns.last, last.speaker == speaker, start - last.end < 1.0 {
                turns[turns.count - 1] = Turn(speaker: speaker, start: last.start, end: end)
            } else {
                turns.append(Turn(speaker: speaker, start: start, end: end))
            }
        }
        return turns
    }

    /// Cosine similarity threshold for matching speakers. Lower = harder to merge.
    private static let similarityFloor: Float = 0.45
    private static let maxSnippetSeconds = 6.0
    private static let maxSnippetsPerSpeaker = 3
    private static let turnEdgeTrim = 0.25
    private static let minEmbeddingSamples = 8000  // 0.5 s @ 16 kHz, the model's reliability floor

    private static let modelBox = ModelBox()

    private actor ModelBox {
        private var model: WeSpeakerModel?
        func embed(_ samples: [Float]) async throws -> [Float] {
            if model == nil { model = try await WeSpeakerModel.fromPretrained() }
            return model!.embed(audio: samples, sampleRate: 16000)
        }
    }

    struct Assignments {
        var byFileLocal: [String: [String: Int]] = [:]
        var newEntries: [(id: Int, centroid: [Float])] = []
    }

    /// Assigns local speaker labels to global speaker ids by matching fingerprints to centroids; new speakers get new ids.
    static func assignments(
        files: [(mediaRef: String, url: URL, turns: [Turn])],
        registry: [(id: Int, centroid: [Float])]
    ) async -> Assignments {
        var out = Assignments()
        var vectors: [(mediaRef: String, local: String, vector: [Float])] = []
        for file in files where !file.turns.isEmpty {
            let prints = await fingerprints(url: file.url, mediaRef: file.mediaRef, turns: file.turns)
            for (local, vector) in prints.sorted(by: { $0.key < $1.key }) {
                vectors.append((file.mediaRef, local, vector))
            }
        }
        guard !vectors.isEmpty else { return out }

        var clusters: [(id: Int, centroid: [Float], refs: Set<String>, isNew: Bool)] =
            registry.map { ($0.id, $0.centroid, [], false) }
        var nextId = (registry.map(\.id).max() ?? 0) + 1
        for item in vectors {
            var best = -1
            var bestSim = similarityFloor
            for (c, cluster) in clusters.enumerated() where !cluster.refs.contains(item.mediaRef) {
                let sim = cosine(item.vector, cluster.centroid)
                if sim >= bestSim { best = c; bestSim = sim }
            }
            if best < 0 {
                clusters.append((nextId, item.vector, [], true))
                nextId += 1
                best = clusters.count - 1
            }
            clusters[best].refs.insert(item.mediaRef)
            out.byFileLocal[item.mediaRef, default: [:]][item.local] = clusters[best].id
        }
        out.newEntries = clusters.filter(\.isNew).map { ($0.id, $0.centroid) }
        return out
    }

    private static func fingerprints(url: URL, mediaRef: String, turns: [Turn]) async -> [String: [Float]] {
        let cacheURL = cache.directory.appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: url))_voices.json")
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([String: [Float]].self, from: data) {
            return cached
        }
        var bySpeaker: [String: [Turn]] = [:]
        for turn in turns where turn.end - turn.start >= 1.0 {
            bySpeaker[turn.speaker, default: []].append(turn)
        }
        var prints: [String: [Float]] = [:]
        for (speaker, all) in bySpeaker {
            let picks = all.sorted { ($0.end - $0.start) > ($1.end - $1.start) }.prefix(maxSnippetsPerSpeaker)
            var sum: [Float]?
            for turn in picks {
                var samples: [Float] = []
                for span in await speechSpans(in: turn, url: url, mediaRef: mediaRef) {
                    if let read = try? await AudioTrackReader.readMonoFloats(from: url, sampleRate: 16000, range: span) {
                        samples.append(contentsOf: read)
                    }
                }
                guard samples.count >= minEmbeddingSamples,
                      let vector = try? await modelBox.embed(samples) else { continue }
                sum = sum.map { zip($0, vector).map(+) } ?? vector
            }
            if let sum { prints[speaker] = normalized(sum) }
        }
        // Empty prints usually mean a transient failure (offline model fetch) — don't cache them.
        if !prints.isEmpty, let data = try? JSONEncoder().encode(prints) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return prints
    }

    static func speechConfirmed(_ turns: [Turn], url: URL, mediaRef: String) async -> [Turn] {
        guard let analysis = try? await VoiceActivity.analysis(for: url, mediaRef: mediaRef),
              !analysis.segments.isEmpty else { return [] }
        return turns.filter { turn in
            analysis.segments.contains { min(turn.end, $0.end) - max(turn.start, $0.start) >= 0.3 }
        }
    }

    /// Skips silence and trims edges before embedding.
    private static func speechSpans(in turn: Turn, url: URL, mediaRef: String) async -> [ClosedRange<Double>] {
        let start = turn.start + turnEdgeTrim
        let end = min(turn.end, turn.start + maxSnippetSeconds) - turnEdgeTrim
        guard end - start >= 0.5 else { return [] }
        // Compute-or-cache; a fresh import gets real spans (and dead-air marking inherits the sidecar).
        guard let analysis = try? await VoiceActivity.analysis(for: url, mediaRef: mediaRef), !analysis.segments.isEmpty else {
            return [start...end]
        }
        var spans: [ClosedRange<Double>] = []
        for segment in analysis.segments {
            let lo = max(start, segment.start)
            let hi = min(end, segment.end)
            if hi - lo >= 0.3 { spans.append(lo...hi) }
        }
        return spans
    }

    private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        let denom = (na * nb).squareRoot()
        return denom > 0 ? dot / denom : 0
    }

    private static func mean(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var out = [Float](repeating: 0, count: first.count)
        for v in vectors where v.count == out.count {
            for i in out.indices { out[i] += v[i] }
        }
        let n = Float(vectors.count)
        return out.map { $0 / n }
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        let norm = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? v.map { $0 / norm } : v
    }
}
