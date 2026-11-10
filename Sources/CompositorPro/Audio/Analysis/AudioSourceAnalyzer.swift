import AVFoundation
import Foundation

struct AudioSourceAnalysis: Codable, Sendable, Equatable {
    let durationSeconds: Double
    let channelCount: Int
    let sampleRate: Double
    let channelLayout: String
    let loudnessStatus: String
    let integratedLUFS: Double?
    let truePeakDBTP: Double?
    let samplePeakDBFS: Double?
    let rmsDBFS: Double?
    let clippedSamples: Int64
    let silenceDurationSeconds: Double
    let silenceRatio: Double
    let speechDetected: Bool
    let contentType: String
    let qualityWarnings: [String]

    var receipt: [String: Any] {
        let row: [String: Any] = [
            "durationSeconds": durationSeconds,
            "channelCount": channelCount,
            "sampleRate": sampleRate,
            "channelLayout": channelLayout,
            "loudnessStatus": loudnessStatus,
            "integratedLUFS": integratedLUFS as Any? ?? NSNull(),
            "truePeakDBTP": truePeakDBTP as Any? ?? NSNull(),
            "samplePeakDBFS": samplePeakDBFS as Any? ?? NSNull(),
            "rmsDBFS": rmsDBFS as Any? ?? NSNull(),
            "clippedSamples": clippedSamples,
            "silenceDurationSeconds": silenceDurationSeconds,
            "silenceRatio": silenceRatio,
            "speechDetected": speechDetected,
            "contentType": contentType,
            "qualityWarnings": qualityWarnings,
        ]
        return row
    }
}

enum AudioSourceAnalyzer {
    @concurrent
    static func analyze(url: URL, range: CMTimeRange? = nil) async throws -> AudioSourceAnalysis {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            return AudioSourceAnalysis(
                durationSeconds: 0, channelCount: 0, sampleRate: 0, channelLayout: "none",
                loudnessStatus: "noAudioTrack", integratedLUFS: nil, truePeakDBTP: nil,
                samplePeakDBFS: nil, rmsDBFS: nil, clippedSamples: 0,
                silenceDurationSeconds: 0, silenceRatio: 1.0, speechDetected: false,
                contentType: "silence", qualityWarnings: ["no_audio_track"]
            )
        }

        let assetDuration = try await asset.load(.duration).seconds
        let duration = range.map { $0.duration.seconds } ?? assetDuration
        let descriptions = try await track.load(.formatDescriptions)

        var channelCount = 2
        var sampleRate = 48000.0
        if let desc = descriptions.first, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
            channelCount = Int(basic.pointee.mChannelsPerFrame)
            sampleRate = basic.pointee.mSampleRate
        }

        let layoutName: String
        switch channelCount {
        case 1: layoutName = "mono"
        case 2: layoutName = "stereo"
        case 6: layoutName = "5.1"
        default: layoutName = "\(channelCount) channels"
        }

        var loudness: LoudnessMeasurement?
        do {
            loudness = try await LoudnessAnalyzer.integratedLoudness(
                for: url, mediaRef: url.lastPathComponent, range: range
            )
        } catch {
            loudness = nil
        }

        var peak: Float = 0
        var energy: Double = 0
        var totalSamples: Int64 = 0
        var clipped: Int64 = 0
        var silentSamples: Int64 = 0

        try await AudioTrackReader.read(from: url, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ], timeRange: range) { buffer in
            guard let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.format.channelCount)
            for ch in 0..<count {
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = abs(channels[ch][frame])
                    if sample.isFinite {
                        peak = max(peak, sample)
                        energy += Double(sample * sample)
                        totalSamples += 1
                        if sample >= 1.0 { clipped += 1 }
                        if sample < 0.001 { silentSamples += 1 }
                    }
                }
            }
        }

        let rms = (totalSamples > 0 && energy > 0) ? 10 * log10(energy / Double(totalSamples)) : nil
        let samplePeakDB = peak > 0 ? 20 * log10(Double(peak)) : nil
        let silenceRatio = totalSamples > 0 ? Double(silentSamples) / Double(totalSamples) : 1.0
        let silenceDuration = duration * silenceRatio

        var speech = false
        if let transcript = TranscriptCache.cachedOnDisk(for: url) {
            speech = !transcript.segments.isEmpty
        } else {
            do {
                let vad = try await VoiceActivity.analysis(for: url, mediaRef: url.lastPathComponent)
                speech = !vad.segments.isEmpty
            } catch {
                speech = false
            }
        }

        let contentType: String
        if silenceRatio > 0.95 || rms == nil || (rms ?? 0) < -55 {
            contentType = "silence"
        } else if speech {
            contentType = "speech"
        } else if duration <= 5.0 || (samplePeakDB != nil && rms != nil && (samplePeakDB! - rms!) > 14.0) {
            contentType = "sfx"
        } else {
            contentType = "music"
        }

        var warnings: [String] = []
        if clipped > 0 || (loudness?.truePeakDBFS ?? -99) > 0.0 {
            warnings.append("clipping_detected")
        }
        if silenceRatio > 0.9 {
            warnings.append("near_silent")
        }
        if (loudness?.truePeakDBFS ?? -99) > -0.5 {
            warnings.append("low_headroom")
        }
        if let rms, rms < -45 {
            warnings.append("low_level")
        }

        return AudioSourceAnalysis(
            durationSeconds: duration,
            channelCount: channelCount,
            sampleRate: sampleRate,
            channelLayout: layoutName,
            loudnessStatus: loudness?.status.rawValue ?? "unmeasured",
            integratedLUFS: loudness?.integratedLUFS,
            truePeakDBTP: loudness?.truePeakDBFS,
            samplePeakDBFS: samplePeakDB,
            rmsDBFS: rms,
            clippedSamples: clipped,
            silenceDurationSeconds: silenceDuration,
            silenceRatio: silenceRatio,
            speechDetected: speech,
            contentType: contentType,
            qualityWarnings: warnings
        )
    }
}
