import Foundation

/// Session store for VAD speech masks and derived dead-air spans (32 ms cells).
@MainActor
final class SpeechMaskStore {
    private var speechMasks: [String: [Bool]] = [:]
    private var deadAirMasks: [String: [Bool]] = [:]
    private var failed: Set<String> = []
    private var epoch: [String: Int] = [:]
    private var inFlight: Set<String> = [] {
        didSet { if inFlight.count != oldValue.count { onAnalyzingCountChange?(inFlight.count) } }
    }

    var onAnalyzingCountChange: ((Int) -> Void)?
    var onMaskReady: (() -> Void)?

    func generate(for asset: MediaAsset) {
        let key = asset.id
        guard speechMasks[key] == nil, !inFlight.contains(key), !failed.contains(key) else { return }
        inFlight.insert(key)
        let startEpoch = epoch[key, default: 0]

        let url = asset.url
        Task.detached(priority: .utility) { [weak self] in
            var mask: [Bool]?
            do {
                let analysis = try await VoiceActivity.analysis(for: url, mediaRef: key)
                mask = analysis.mask
                Log.preview.notice("vad ok mediaRef=\(key) segments=\(analysis.segments.count) chunks=\(analysis.chunkCount)")
            } catch {
                Log.preview.error("vad failed mediaRef=\(key): \(Log.detail(error))")
            }
            guard let self else { return }
            await MainActor.run { [self] in
                guard self.epoch[key, default: 0] == startEpoch else { return }
                self.inFlight.remove(key)
                if let mask {
                    self.speechMasks[key] = mask
                    self.deadAirMasks.removeValue(forKey: key)
                    if !mask.isEmpty { self.onMaskReady?() }
                } else {
                    self.failed.insert(key)
                }
            }
        }
    }

    /// Drops all session state so cleared disk caches regenerate.
    func reset() {
        for key in inFlight { epoch[key, default: 0] += 1 }
        inFlight.removeAll()
        speechMasks.removeAll()
        deadAirMasks.removeAll()
        failed.removeAll()
    }

    func invalidate(_ mediaRef: String) {
        epoch[mediaRef, default: 0] += 1
        inFlight.remove(mediaRef)
        speechMasks.removeValue(forKey: mediaRef)
        deadAirMasks.removeValue(forKey: mediaRef)
        failed.remove(mediaRef)
    }

    // MARK: - Dead air

    // Marks a span as dead air if its median level is `speechGap` below the file's speech level, using normalized waveform values.
    private nonisolated static let speechGap: Float = 0.24      // 12 dB
    private nonisolated static let noSpeechFloor: Float = 0.56  // absolute fallback ≈ -28 dB
    private nonisolated static let minCells = 8                 // ≈ 0.26 s

    /// Derived lazily once the speech mask and waveform samples both exist.
    nonisolated func deadAirMask(for mediaRef: String, samples: [Float]?) -> [Bool]? {
        MainActor.assumeIsolated {
            if let cached = deadAirMasks[mediaRef] { return cached }
            guard let speech = speechMasks[mediaRef], !speech.isEmpty,
                  let samples, !samples.isEmpty else { return nil }
            let mask = Self.buildDeadAirMask(speech: speech, samples: samples)
            deadAirMasks[mediaRef] = mask
            return mask
        }
    }

    private nonisolated static func buildDeadAirMask(speech: [Bool], samples: [Float]) -> [Bool] {
        let n = speech.count
        func cellPeak(_ c: Int) -> Float {
            let s0 = c * samples.count / n
            let s1 = min(samples.count, max(s0 + 1, (c + 1) * samples.count / n))
            var peak: Float = 1
            for s in s0..<s1 where samples[s] < peak { peak = samples[s] }
            return peak
        }
        func median(_ values: [Float]) -> Float { values.sorted()[values.count / 2] }

        let speechPeaks = (0..<n).filter { speech[$0] }.map(cellPeak)
        let quietFloor = speechPeaks.isEmpty
            ? noSpeechFloor
            : min(0.8, max(0.44, median(speechPeaks) + speechGap))

        var dead = [Bool](repeating: false, count: n)
        var i = 0
        while i < n {
            guard !speech[i] else { i += 1; continue }
            var j = i
            while j < n && !speech[j] { j += 1 }
            if j - i >= Self.minCells, median((i..<j).map(cellPeak)) >= quietFloor {
                for c in i..<j { dead[c] = true }
            }
            i = j
        }
        return dead
    }
}
