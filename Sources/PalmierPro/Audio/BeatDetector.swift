import AVFoundation
import Accelerate
import Foundation

struct BeatAnalysis: Sendable {
    let bpm: Double
    let beats: [Double]      // seconds
    let downbeats: [Double]  // bar starts (every 4 beats), seconds
    let confidence: Double   // 0–1
    let durationSeconds: Double
    let climaxSec: Double    // peak of the smoothed energy envelope — the song's climax, seconds
    let energyCurve: [Double] // coarse energy curve, 0–1, one value per energyStepSec
    let energyStepSec: Double
}

enum BeatDetectorError: LocalizedError {
    case noAudioTrack
    case readFailed(String)
    case insufficientData

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:       return "No audio track found in asset."
        case .readFailed(let r):  return "Audio read failed: \(r)"
        case .insufficientData:   return "Audio too short to analyze (need at least 2 seconds)."
        }
    }
}

enum BeatDetector {
    private static let targetSampleRate: Double = 22050
    private static let hopSize = 512
    private static let fftSize = 2048
    private static let bpmMin: Double = 60
    private static let bpmMax: Double = 200

    static func analyze(url: URL) async throws -> BeatAnalysis {
        let (samples, duration) = try await loadMonoPCM(url: url)
        guard samples.count >= fftSize * 2 else { throw BeatDetectorError.insufficientData }

        let onsetEnv = computeOnsetStrength(samples: samples)
        let hopDuration = Double(hopSize) / targetSampleRate
        let bpm = estimateBPM(onsetEnv: onsetEnv, hopDuration: hopDuration)
        let beats = pickBeats(onsetEnv: onsetEnv, hopDuration: hopDuration, bpm: bpm)
        let downbeats = stride(from: 0, to: beats.count, by: 4).map { beats[$0] }
        let confidence = computeConfidence(onsetEnv: onsetEnv, beats: beats, hopDuration: hopDuration)
        let energy = computeEnergy(onsetEnv: onsetEnv, hopDuration: hopDuration)

        return BeatAnalysis(
            bpm: bpm,
            beats: beats,
            downbeats: downbeats,
            confidence: confidence,
            durationSeconds: duration,
            climaxSec: energy.climaxSec,
            energyCurve: energy.curve,
            energyStepSec: energy.stepSec
        )
    }

    // MARK: - Energy / climax

    /// Smooths the onset envelope with a ~3 s moving average into a loudness-like energy curve.
    /// The peak of the smoothed curve is the song's climax (chorus/drop); the downsampled curve
    /// lets callers see the overall build/quiet structure.
    private static func computeEnergy(
        onsetEnv: [Float], hopDuration: Double
    ) -> (climaxSec: Double, curve: [Double], stepSec: Double) {
        guard !onsetEnv.isEmpty else { return (0, [], 0) }
        let window = max(1, Int((3.0 / hopDuration).rounded()))
        var smoothed = [Float](repeating: 0, count: onsetEnv.count)
        var sum: Float = 0
        for i in 0..<onsetEnv.count {
            sum += onsetEnv[i]
            if i >= window { sum -= onsetEnv[i - window] }
            smoothed[i] = sum / Float(min(i + 1, window))
        }

        var maxIdx = 0
        var maxVal: Float = 0
        for (i, v) in smoothed.enumerated() where v > maxVal { maxVal = v; maxIdx = i }
        // The trailing average lags by half a window; recenter so the time lands on the peak itself.
        let climaxSec = Double(max(0, maxIdx - window / 2)) * hopDuration

        // Downsample to at most ~120 points (>= 2 s per point), normalized 0–1.
        let stepSec = max(2.0, hopDuration * Double(smoothed.count) / 120.0)
        let hopsPerStep = max(1, Int((stepSec / hopDuration).rounded()))
        var curve: [Double] = []
        var i = 0
        while i < smoothed.count {
            let end = min(i + hopsPerStep, smoothed.count)
            var peak: Float = 0
            for j in i..<end where smoothed[j] > peak { peak = smoothed[j] }
            curve.append(maxVal > 0 ? Double(peak / maxVal) : 0)
            i = end
        }
        return (climaxSec, curve, stepSec)
    }

    // MARK: - Audio loading

    private static func loadMonoPCM(url: URL) async throws -> ([Float], Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .audio).first else {
            throw BeatDetectorError.noAudioTrack
        }
        let assetDuration = (try? await asset.load(.duration))?.seconds ?? 0

        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) }
        catch { throw BeatDetectorError.readFailed(error.localizedDescription) }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(output) else { throw BeatDetectorError.readFailed("Cannot configure audio output") }
        reader.add(output)
        guard reader.startReading() else {
            throw BeatDetectorError.readFailed(reader.error?.localizedDescription ?? "reader failed to start")
        }

        var samples: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
            guard frameCount > 0 else { continue }
            guard let desc = CMSampleBufferGetFormatDescription(sample),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc),
                  let format = AVAudioFormat(streamDescription: asbd),
                  let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { continue }
            pcm.frameLength = frameCount
            CMSampleBufferCopyPCMDataIntoAudioBufferList(
                sample, at: 0, frameCount: Int32(frameCount), into: pcm.mutableAudioBufferList
            )
            guard let ptr = pcm.floatChannelData?[0] else { continue }
            samples.append(contentsOf: UnsafeBufferPointer(start: ptr, count: Int(frameCount)))
        }
        return (samples, assetDuration)
    }

    // MARK: - Spectral flux onset strength

    private static func computeOnsetStrength(samples: [Float]) -> [Float] {
        let n = samples.count
        let numHops = (n - fftSize) / hopSize + 1
        guard numHops > 1 else { return [] }

        let log2n = vDSP_Length(log2(Double(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        let halfFFT = fftSize / 2
        var prevMag = [Float](repeating: 0, count: halfFFT)
        var curMag  = [Float](repeating: 0, count: halfFFT)
        var realParts = [Float](repeating: 0, count: halfFFT)
        var imagParts = [Float](repeating: 0, count: halfFFT)
        var onsetStrength = [Float](repeating: 0, count: numHops)

        for hop in 0..<numHops {
            let start = hop * hopSize
            var frame = [Float](repeating: 0, count: fftSize)
            let frameEnd = min(start + fftSize, n)
            for i in start..<frameEnd { frame[i - start] = samples[i] * window[i - start] }

            realParts.withUnsafeMutableBufferPointer { rPtr in
                imagParts.withUnsafeMutableBufferPointer { iPtr in
                    var split = DSPSplitComplex(realp: rPtr.baseAddress!, imagp: iPtr.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        let cPtr = raw.baseAddress!.assumingMemoryBound(to: DSPComplex.self)
                        vDSP_ctoz(cPtr, 2, &split, 1, vDSP_Length(halfFFT))
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &curMag, 1, vDSP_Length(halfFFT))

                    // Half-wave rectified spectral flux
                    var flux: Float = 0
                    for i in 0..<halfFFT {
                        let diff = curMag[i] - prevMag[i]
                        if diff > 0 { flux += diff }
                    }
                    onsetStrength[hop] = flux
                    swap(&prevMag, &curMag)
                }
            }
        }

        // Normalize to [0, 1]
        var maxVal: Float = 0
        vDSP_maxv(onsetStrength, 1, &maxVal, vDSP_Length(numHops))
        if maxVal > 0 {
            var scale = 1.0 / maxVal
            vDSP_vsmul(onsetStrength, 1, &scale, &onsetStrength, 1, vDSP_Length(numHops))
        }
        return onsetStrength
    }

    // MARK: - BPM via autocorrelation

    private static func estimateBPM(onsetEnv: [Float], hopDuration: Double) -> Double {
        let n = onsetEnv.count
        let minLag = max(1, Int((60.0 / bpmMax / hopDuration).rounded()))
        let maxLag = min(n - 1, Int((60.0 / bpmMin / hopDuration).rounded()))
        guard minLag < maxLag else { return 120 }

        var bestLag = minLag
        var bestCorr: Double = -Double.infinity
        for lag in minLag...maxLag {
            var corr: Double = 0
            for i in 0..<(n - lag) {
                corr += Double(onsetEnv[i]) * Double(onsetEnv[i + lag])
            }
            if corr > bestCorr {
                bestCorr = corr
                bestLag = lag
            }
        }

        let rawBPM = 60.0 / (Double(bestLag) * hopDuration)
        return (rawBPM * 10).rounded() / 10
    }

    // MARK: - Beat picking

    private static func pickBeats(onsetEnv: [Float], hopDuration: Double, bpm: Double) -> [Double] {
        let n = onsetEnv.count
        let periodInt = max(1, Int((60.0 / bpm / hopDuration).rounded()))

        // Find the phase (0..<periodInt) that maximises total onset strength on beats
        var bestPhase = 0
        var bestScore: Float = -Float.infinity
        for phase in 0..<periodInt {
            var score: Float = 0
            var hop = phase
            while hop < n { score += onsetEnv[hop]; hop += periodInt }
            if score > bestScore { bestScore = score; bestPhase = phase }
        }

        var beats: [Double] = []
        var hop = bestPhase
        while hop < n { beats.append(Double(hop) * hopDuration); hop += periodInt }
        return beats
    }

    // MARK: - Confidence

    private static func computeConfidence(onsetEnv: [Float], beats: [Double], hopDuration: Double) -> Double {
        guard !beats.isEmpty, !onsetEnv.isEmpty else { return 0 }
        var beatStrength: Float = 0
        for beat in beats {
            let hop = min(Int((beat / hopDuration).rounded()), onsetEnv.count - 1)
            beatStrength += onsetEnv[hop]
        }
        beatStrength /= Float(beats.count)
        var mean: Float = 0
        vDSP_meanv(onsetEnv, 1, &mean, vDSP_Length(onsetEnv.count))
        guard mean > 0 else { return 0 }
        return min(1.0, Double(beatStrength / mean) / 2.5)
    }
}
