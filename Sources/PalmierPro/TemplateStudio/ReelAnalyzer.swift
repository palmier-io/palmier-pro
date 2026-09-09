import AVFoundation
import Foundation

struct ReelAnalysis: Codable, Sendable, Equatable {
    var shots: [DetectedShot]
    var audioSegments: [AudioSegment]
    /// Beat times in source-media seconds; empty when no music was detected.
    var beats: [Double]
    var durationSeconds: Double
    var sourceWidth: Int
    var sourceHeight: Int
    var sourceFPS: Double
    var hasAudio: Bool

    var musicSegments: [AudioSegment] { audioSegments.filter { $0.kind == .music } }
    var speechSegments: [AudioSegment] { audioSegments.filter { $0.kind == .speech } }
}

struct ReelAnalysisProgress: Sendable, Equatable {
    enum Stage: Sendable, Equatable {
        case scenes
        case audio
        case beats
    }

    var stage: Stage
    /// 0–1 within the current stage.
    var fraction: Double
}

/// Runs scene, audio, and beat analysis for a reel and caches the result per asset revision.
enum ReelAnalyzer {
    enum AnalyzeError: LocalizedError {
        case notAVideo
        case emptyMedia
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAVideo: "The media has no video track."
            case .emptyMedia: "The media has zero or indefinite duration."
            case .failed(let reason): reason
            }
        }
    }

    private static let cache = DiskCache(named: "ReelAnalysis")

    @concurrent
    static func analysis(
        for sourceURL: URL,
        mediaRef: String,
        force: Bool = false,
        progress: (@Sendable (ReelAnalysisProgress) -> Void)? = nil
    ) async throws -> ReelAnalysis {
        if !force, let cached = cachedAnalysis(for: sourceURL, mediaRef: mediaRef) {
            return cached
        }
        try Task.checkCancellation()

        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw AnalyzeError.notAVideo
        }
        let naturalSize = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let displaySize = naturalSize.applying(transform)
        let nominalFPS = Double(try await videoTrack.load(.nominalFrameRate))
        let durationSeconds = (try await videoTrack.load(.timeRange)).duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else { throw AnalyzeError.emptyMedia }
        let hasAudio = !((try? await asset.loadTracks(withMediaType: .audio)) ?? []).isEmpty

        progress?(ReelAnalysisProgress(stage: .scenes, fraction: 0))
        let shots = try await SceneCutDetector.detectShots(in: sourceURL) { fraction in
            progress?(ReelAnalysisProgress(stage: .scenes, fraction: fraction))
        }
        try Task.checkCancellation()

        var audioSegments: [AudioSegment] = []
        if hasAudio {
            progress?(ReelAnalysisProgress(stage: .audio, fraction: 0))
            audioSegments = try await AudioSegmentClassifier.classifySegments(in: sourceURL)
            progress?(ReelAnalysisProgress(stage: .audio, fraction: 1))
        }
        try Task.checkCancellation()

        var beats: [Double] = []
        if audioSegments.contains(where: { $0.kind == .music }) {
            progress?(ReelAnalysisProgress(stage: .beats, fraction: 0))
            // Beats enrich the template; a reel whose beat pass fails is still a valid template.
            beats = (try? await BeatDetector.analysis(for: sourceURL, mediaRef: mediaRef))?.beats ?? []
            progress?(ReelAnalysisProgress(stage: .beats, fraction: 1))
        }
        try Task.checkCancellation()

        let analysis = ReelAnalysis(
            shots: shots,
            audioSegments: audioSegments,
            beats: beats,
            durationSeconds: durationSeconds,
            sourceWidth: Int(abs(displaySize.width)),
            sourceHeight: Int(abs(displaySize.height)),
            sourceFPS: nominalFPS > 0 ? nominalFPS : 30,
            hasAudio: hasAudio
        )
        persist(analysis, for: sourceURL, mediaRef: mediaRef)
        return analysis
    }

    // MARK: - Cache

    private static func cachedAnalysis(for sourceURL: URL, mediaRef: String) -> ReelAnalysis? {
        guard let data = try? Data(contentsOf: analysisURL(for: sourceURL, mediaRef: mediaRef)) else { return nil }
        return try? JSONDecoder().decode(ReelAnalysis.self, from: data)
    }

    private static func persist(_ analysis: ReelAnalysis, for sourceURL: URL, mediaRef: String) {
        let outputURL = analysisURL(for: sourceURL, mediaRef: mediaRef)
        removeStaleCaches(for: mediaRef, keeping: outputURL)
        guard let data = try? JSONEncoder().encode(analysis) else { return }
        try? data.write(to: outputURL)
    }

    private static func analysisURL(for sourceURL: URL, mediaRef: String) -> URL {
        cache.directory.appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_reel.json")
    }

    private static func removeStaleCaches(for mediaRef: String, keeping keep: URL) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: cache.directory,
            includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries
        where entry.lastPathComponent.hasPrefix("\(mediaRef)_") && entry.lastPathComponent != keep.lastPathComponent {
            try? fileManager.removeItem(at: entry)
        }
    }
}
