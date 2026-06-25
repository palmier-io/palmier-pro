import Foundation

struct SilenceConfig: Sendable, Equatable {
    var thresholdLinear: Float = 0.018  // ~-35dB RMS
    var minSilenceDuration: Double = 0.5
    var edgePaddingSeconds: Double = 0.05
}

enum SilenceDetector {
    static func detect(envelope: AudioEnvelope, config: SilenceConfig) -> [(start: Double, end: Double)] {
        var runs: [(start: Double, end: Double)] = []
        var runStart: Double?
        let hop = envelope.hopSeconds

        for (i, sample) in envelope.samples.enumerated() {
            let t = Double(i) * hop
            if sample < config.thresholdLinear {
                if runStart == nil { runStart = t }
            } else if let rs = runStart {
                runs.append((start: rs, end: t))
                runStart = nil
            }
        }
        if let rs = runStart {
            runs.append((start: rs, end: envelope.duration))
        }

        let pad = config.edgePaddingSeconds
        return runs.compactMap { run in
            guard run.end - run.start >= config.minSilenceDuration else { return nil }
            let trimStart = run.start + pad
            let trimEnd = run.end - pad
            guard trimEnd > trimStart else { return nil }
            return (start: trimStart, end: trimEnd)
        }
    }

    /// Map source-second silence ranges onto the timeline, honoring the clip's
    /// position, trim, and speed. Ranges outside the visible content are dropped.
    static func timelineRanges(
        silences: [(start: Double, end: Double)],
        clip: Clip,
        fps: Int
    ) -> [FrameRange] {
        let fpsD = Double(fps)
        let trimStartS = Double(clip.trimStartFrame) / fpsD
        let clipContentEndS = trimStartS + Double(clip.durationFrames) * clip.speed / fpsD

        return silences.compactMap { silence in
            let cs = max(silence.start, trimStartS)
            let ce = min(silence.end, clipContentEndS)
            guard ce > cs else { return nil }
            let tlStart = clip.startFrame + Int(((cs - trimStartS) / clip.speed * fpsD).rounded())
            let tlEnd = clip.startFrame + Int(((ce - trimStartS) / clip.speed * fpsD).rounded())
            guard tlEnd > tlStart else { return nil }
            return FrameRange(start: tlStart, end: tlEnd)
        }
    }
}
