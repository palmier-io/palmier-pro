import AVFoundation
import SpeechVAD

/// Silero VAD speech detection; results cache as JSON sidecars keyed to the source file (AudioEnhancer's scheme).
enum VoiceActivity {
    static let cache = DiskCache(named: "AudioAnalysis")
    static let chunkDuration = Double(SileroVADModel.chunkSize) / Double(SileroVADModel.sampleRate)

    struct Span: Codable {
        let start: Double
        let end: Double
    }

    struct Analysis: Codable {
        /// Number of 32 ms VAD cells spanning the full source duration.
        let chunkCount: Int
        /// Speech spans in source seconds.
        let segments: [Span]

        /// Per-cell speech flags; index maps uniformly onto the source duration.
        var mask: [Bool] {
            var mask = [Bool](repeating: false, count: chunkCount)
            for span in segments {
                let lo = max(0, Int(span.start / VoiceActivity.chunkDuration))
                let hi = min(chunkCount, Int((span.end / VoiceActivity.chunkDuration).rounded(.up)))
                guard lo < hi else { continue }
                for i in lo..<hi { mask[i] = true }
            }
            return mask
        }
    }

    private static let modelBox = ModelBox()

    /// Silero is not thread-safe; the actor serializes model use.
    private actor ModelBox {
        private var model: SileroVADModel?

        func analyze(samples: [Float]) async throws -> Analysis {
            // .mlx pinned: the CoreML engine soft-fails per chunk on ANE errors, caching empty segments as truth.
            let vad: SileroVADModel
            if let model {
                vad = model
            } else {
                try MLXRuntime.requireAvailable()
                vad = try await SileroVADModel.fromPretrained(engine: .mlx)
                model = vad
            }
            guard !samples.isEmpty else { return Analysis(chunkCount: 0, segments: []) }
            let segments = vad.detectSpeech(audio: samples, sampleRate: SileroVADModel.sampleRate)
            let chunkCount = (samples.count + SileroVADModel.chunkSize - 1) / SileroVADModel.chunkSize
            return Analysis(
                chunkCount: chunkCount,
                segments: segments.map { Span(start: Double($0.startTime), end: Double($0.endTime)) }
            )
        }
    }

    /// Two in flight: one file decodes while the previous one runs inference in the
    /// (serial) model actor, with memory bounded to two decoded files.
    private static let pipelineGate = AsyncSemaphore(value: 2)

    static func analysis(for sourceURL: URL, mediaRef: String) async throws -> Analysis {
        if let cached = cachedAnalysis(for: sourceURL, mediaRef: mediaRef) { return cached }
        try await pipelineGate.wait()
        defer { Task { await pipelineGate.signal() } }
        let samples = try await AudioTrackReader.readMonoFloats(from: sourceURL, sampleRate: Double(SileroVADModel.sampleRate))
        let analysis = try await modelBox.analyze(samples: samples)
        let outputURL = analysisURL(for: sourceURL, mediaRef: mediaRef)
        removeStaleCaches(for: mediaRef, keeping: outputURL)
        if let data = try? JSONEncoder().encode(analysis) {
            try? data.write(to: outputURL)
        }
        return analysis
    }

    static func cachedAnalysis(for sourceURL: URL, mediaRef: String) -> Analysis? {
        guard let data = try? Data(contentsOf: analysisURL(for: sourceURL, mediaRef: mediaRef)) else { return nil }
        return try? JSONDecoder().decode(Analysis.self, from: data)
    }

    private static func analysisURL(for sourceURL: URL, mediaRef: String) -> URL {
        cache.directory.appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_vad.json")
    }

    private static func removeStaleCaches(for mediaRef: String, keeping keep: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("\(mediaRef)_") && entry.lastPathComponent != keep.lastPathComponent {
            try? fm.removeItem(at: entry)
        }
    }
}
