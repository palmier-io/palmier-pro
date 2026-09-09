import AVFoundation
import Foundation
import SoundAnalysis

enum AudioSegmentKind: String, Codable, Sendable {
    case music
    case speech
    case silence

    var trackName: String {
        switch self {
        case .music: L10n.key("Music")
        case .speech: L10n.key("Voice")
        case .silence: L10n.key("Silence")
        }
    }
}

struct AudioSegment: Codable, Sendable, Equatable {
    var kind: AudioSegmentKind
    var startSeconds: Double
    var durationSeconds: Double
    var confidence: Double

    var endSeconds: Double { startSeconds + durationSeconds }
}

/// Classifies a reel's mixed audio into music / speech / silence spans
/// using the built-in SoundAnalysis classifier.
enum AudioSegmentClassifier {
    private static let minimumConfidence = 0.45
    private static let mergeGapSeconds = 0.75
    private static let minimumSegmentSeconds = 1.0

    @concurrent
    static func classifySegments(in sourceURL: URL) async throws -> [AudioSegment] {
        let asset = AVURLAsset(url: sourceURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let durationSeconds = (try await audioTrack.load(.timeRange)).duration.seconds
        guard durationSeconds.isFinite, durationSeconds > 0 else { return [] }
        try Task.checkCancellation()

        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(value: 1, timescale: 1)
        request.overlapFactor = 0.5

        let windows = try await classify(url: sourceURL, request: request)
        try Task.checkCancellation()
        return segments(from: windows, durationSeconds: durationSeconds)
    }

    // MARK: - SoundAnalysis bridge

    private struct ClassifiedWindow: Sendable {
        var startSeconds: Double
        var durationSeconds: Double
        var kind: AudioSegmentKind
        var confidence: Double
    }

    private static func classify(url: URL, request: SNClassifySoundRequest) async throws -> [ClassifiedWindow] {
        let analyzer = try SNAudioFileAnalyzer(url: url)
        let box = AnalyzerBox(analyzer)
        let observer = WindowObserver()
        try analyzer.add(request, withObserver: observer)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                observer.adopt(continuation)
                box.analyzer.analyze { didSucceed in
                    guard !didSucceed else { return }
                    observer.finish(.failure(CancellationError()))
                }
            }
        } onCancel: {
            box.analyzer.cancelAnalysis()
        }
    }

    private final class AnalyzerBox: @unchecked Sendable {
        let analyzer: SNAudioFileAnalyzer

        init(_ analyzer: SNAudioFileAnalyzer) {
            self.analyzer = analyzer
        }
    }

    private final class WindowObserver: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var windows: [ClassifiedWindow] = []
        private var continuation: CheckedContinuation<[ClassifiedWindow], Error>?
        private var finished = false

        func adopt(_ continuation: CheckedContinuation<[ClassifiedWindow], Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let music = result.classification(forIdentifier: "music")?.confidence ?? 0
            let speech = result.classification(forIdentifier: "speech")?.confidence ?? 0

            let kind: AudioSegmentKind
            let confidence: Double
            if speech >= minimumConfidence, speech >= music {
                kind = .speech
                confidence = speech
            } else if music >= minimumConfidence {
                kind = .music
                confidence = music
            } else {
                kind = .silence
                confidence = 1 - max(music, speech)
            }

            lock.lock()
            windows.append(ClassifiedWindow(
                startSeconds: result.timeRange.start.seconds,
                durationSeconds: result.timeRange.duration.seconds,
                kind: kind,
                confidence: confidence
            ))
            lock.unlock()
        }

        func request(_ request: SNRequest, didFailWithError error: Error) {
            finish(.failure(error))
        }

        func requestDidComplete(_ request: SNRequest) {
            lock.lock()
            let collected = windows
            lock.unlock()
            finish(.success(collected))
        }

        func finish(_ result: Result<[ClassifiedWindow], Error>) {
            lock.lock()
            guard !finished, let continuation else {
                lock.unlock()
                return
            }
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        }
    }

    // MARK: - Segment merging

    private static func segments(from windows: [ClassifiedWindow], durationSeconds: Double) -> [AudioSegment] {
        guard !windows.isEmpty else {
            return [AudioSegment(kind: .silence, startSeconds: 0, durationSeconds: durationSeconds, confidence: 1)]
        }

        var merged: [AudioSegment] = []
        for window in windows.sorted(by: { $0.startSeconds < $1.startSeconds }) {
            let start = min(window.startSeconds, durationSeconds)
            let end = min(window.startSeconds + window.durationSeconds, durationSeconds)
            guard end > start else { continue }
            if var last = merged.last, last.kind == window.kind, start - last.endSeconds <= mergeGapSeconds {
                last.confidence = (last.confidence + window.confidence) / 2
                last.durationSeconds = end - last.startSeconds
                merged[merged.count - 1] = last
            } else {
                merged.append(AudioSegment(
                    kind: window.kind,
                    startSeconds: start,
                    durationSeconds: end - start,
                    confidence: window.confidence
                ))
            }
        }

        var debounced: [AudioSegment] = []
        for segment in merged {
            if segment.durationSeconds < minimumSegmentSeconds, var last = debounced.last {
                last.durationSeconds = segment.endSeconds - last.startSeconds
                debounced[debounced.count - 1] = last
            } else {
                debounced.append(segment)
            }
        }
        return debounced.isEmpty ? merged : debounced
    }
}
