import AVFoundation
import CryptoKit
import Foundation

enum LoudnessAnalyzer {
    private static let gate = AsyncSemaphore(value: 1)
    private static let cacheCapacity = 512

    enum AnalysisError: Error, Equatable {
        case invalidSourceRange
        case sourceChanged
    }

    struct SourceVersion: Codable, Equatable, Sendable {
        let url: String
        let size: UInt64
        let modified: Double
        let fileNumber: UInt64

        init(_ url: URL) throws {
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                self.url = url.standardizedFileURL.absoluteString
                size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            } catch {
                // Source file missing or unreadable: report a zero version so change detection
                // still agrees across reads instead of throwing a raw file error.
                self.url = url.standardizedFileURL.absoluteString
                size = 0; modified = 0; fileNumber = 0
            }
        }
    }

    @concurrent
    static func sourceVersions(for urls: [URL]) async throws -> [URL: SourceVersion] {
        var versions: [URL: SourceVersion] = [:]
        for url in Set(urls) {
            try Task.checkCancellation()
            versions[url] = try SourceVersion(url)
        }
        return versions
    }

    @concurrent
    static func validateSourceVersions(_ versions: [URL: SourceVersion]) async throws {
        for (url, version) in versions {
            try Task.checkCancellation()
            guard try SourceVersion(url) == version else { throw AnalysisError.sourceChanged }
        }
    }

    private struct CacheKey: Encodable {
        let version = 4
        let source: SourceVersion
        let mediaRef: String
        let range: String
    }

    /// Source-domain measurement excludes clip gain, fades, and playback-rate processing.
    @concurrent
    static func integratedLoudness(
        for sourceURL: URL, mediaRef: String, range: CMTimeRange? = nil, cacheDirectory: URL? = nil
    ) async throws -> LoudnessMeasurement {
        try validate(range)
        try Task.checkCancellation()
        try await gate.wait()
        do {
            let measurement = try await analyze(sourceURL, mediaRef: mediaRef, range: range, cacheDirectory: cacheDirectory)
            await gate.signal()
            return measurement
        } catch {
            await gate.signal()
            throw error
        }
    }

    static func sourceRange(for clip: Clip, fps: Int) throws -> CMTimeRange {
        guard (1...120).contains(fps), clip.trimStartFrame >= 0, clip.durationFrames > 0,
              clip.durationFrames <= Int.max / 2_000,
              clip.speed.isFinite, (SourceTimeMap.minimumSpeed...SourceTimeMap.maximumSpeed).contains(clip.speed),
              (clip.speedTrack?.keyframes ?? []).allSatisfy({
                  $0.frame >= 0 && $0.frame <= clip.durationFrames && $0.value.isFinite
                      && (SourceTimeMap.minimumSpeed...SourceTimeMap.maximumSpeed).contains($0.value)
              }) else { throw AnalysisError.invalidSourceRange }
        let sourceFrames = clip.timeMap.sourceFramesConsumed
        let end = clip.trimStartFrame.addingReportingOverflow(sourceFrames)
        guard sourceFrames > 0, !end.overflow else { throw AnalysisError.invalidSourceRange }
        return CMTimeRange(
            start: CMTime(value: Int64(clip.trimStartFrame), timescale: CMTimeScale(fps)),
            duration: CMTime(value: Int64(sourceFrames), timescale: CMTimeScale(fps))
        )
    }

    private static func validate(_ range: CMTimeRange?) throws {
        guard let range else { return }
        guard range.isValid, range.start.isNumeric, range.duration.isNumeric, range.end.isNumeric,
              range.start.epoch == 0, range.duration.epoch == 0,
              range.start >= .zero, range.duration > .zero else { throw AnalysisError.invalidSourceRange }
    }

    private static func analyze(
        _ sourceURL: URL, mediaRef: String, range: CMTimeRange?, cacheDirectory: URL?
    ) async throws -> LoudnessMeasurement {
        try Task.checkCancellation()
        let source = try SourceVersion(sourceURL)
        let directory = (cacheDirectory ?? DiskCache.rootDirectory.appendingPathComponent("AudioAnalysis/Loudness", isDirectory: true))
        let rangeKey = range.map { "\($0.start.value)/\($0.start.timescale):\($0.duration.value)/\($0.duration.timescale)" } ?? "whole"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let key = try encoder.encode(CacheKey(source: source, mediaRef: mediaRef, range: rangeKey))
        let filename = SHA256.hash(data: key).map { String(format: "%02x", $0) }.joined() + ".json"
        let cacheURL = directory.appendingPathComponent(filename)
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(LoudnessMeasurement.self, from: data), valid(cached) {
            try Task.checkCancellation()
            return cached
        }

        let measurement = try await readPass(sourceURL, range: range)
        try Task.checkCancellation()
        guard try SourceVersion(sourceURL) == source else { throw AnalysisError.sourceChanged }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(measurement).write(to: cacheURL, options: .atomic)
            try pruneCache(directory, keeping: cacheURL)
        } catch {
            Log.preview.warning("loudness cache write failed mediaRef=\(mediaRef)")
        }
        return measurement
    }

    private static func readPass(_ url: URL, range: CMTimeRange?) async throws -> LoudnessMeasurement {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw LoudnessMeter.MeasurementError.unsupportedFormat
        }
        let formatDesc = try await track.load(.formatDescriptions).first
        guard let formatDesc else {
            throw LoudnessMeter.MeasurementError.unsupportedFormat
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDesc)
        var meter = try LoudnessMeter(format: format)

        try await AudioTrackReader.read(from: url, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: LoudnessMeter.sampleRate,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: true,
        ], timeRange: range) { buffer in
            try meter.consume(buffer)
        }
        return meter.measurement
    }

    private static func valid(_ measurement: LoudnessMeasurement) -> Bool {
        switch measurement.status {
        case .measured:
            measurement.analyzedFrames >= LoudnessMeter.minimumFrames
                && measurement.integratedLUFS?.isFinite == true
        case .belowGate:
            measurement.analyzedFrames >= LoudnessMeter.minimumFrames
                && measurement.integratedLUFS == nil
        case .insufficientDuration:
            measurement.analyzedFrames >= 0
                && measurement.analyzedFrames < LoudnessMeter.minimumFrames
                && measurement.integratedLUFS == nil
        }
    }

    private static func pruneCache(_ directory: URL, keeping cacheURL: URL) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        ).filter { $0.pathExtension == "json" }
        guard files.count > cacheCapacity else { return }
        let dated = try files.filter { $0 != cacheURL }.map {
            ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate ?? .distantPast)
        }.sorted { $0.1 < $1.1 }
        for (url, _) in dated.prefix(files.count - cacheCapacity) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
