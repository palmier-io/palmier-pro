import Foundation

enum AudioSpeechTiming {
    struct Source: Sendable {
        let clip: Clip
        let url: URL
    }

    enum Method: String, Sendable {
        case transcript
        case voiceActivity
        case wholeClip = "whole_clip_fallback"
    }

    struct Timing: Sendable {
        let clipId: String
        let ranges: [Range<Int>]
        let method: Method
    }

    struct Result: Sendable {
        let timings: [Timing]
        let sourceVersions: [URL: LoudnessAnalyzer.SourceVersion]

        var ranges: [Range<Int>] { timings.flatMap(\.ranges) }
        var usedWholeClipFallback: Bool { timings.contains { $0.method == .wholeClip } }
    }

    enum Failure: LocalizedError {
        case unavailable(String)
        case invalidTiming(String)

        var errorDescription: String? {
            switch self {
            case .unavailable(let id): "Speech timing is unavailable for '\(id)'. Transcribe the source or enable bundled speech analysis."
            case .invalidTiming(let id): "Speech analysis returned invalid timing for '\(id)'."
            }
        }
    }

    @concurrent
    static func analyze(_ sources: [Source], fps: Int, allowWholeClipFallback: Bool = false) async throws -> Result {
        var timings: [Timing] = []
        var versions: [URL: LoudnessAnalyzer.SourceVersion] = [:]
        for source in sources {
            try Task.checkCancellation()
            _ = try LoudnessAnalyzer.sourceRange(for: source.clip, fps: fps)
            let version = try LoudnessAnalyzer.SourceVersion(source.url)
            if let previous = versions[source.url], previous != version { throw LoudnessAnalyzer.AnalysisError.sourceChanged }
            versions[source.url] = version
            let spans: [(Double, Double)]
            let method: Method
            if let transcript = TranscriptCache.cachedOnDisk(for: source.url) {
                let words = transcript.words.compactMap { word -> (Double, Double)? in
                    guard let start = word.start, let end = word.end else { return nil }
                    return (start, end)
                }
                spans = words.isEmpty ? transcript.segments.map { ($0.start, $0.end) } : words
                method = .transcript
            } else {
                do {
                    let analysis = try await VoiceActivity.analysis(for: source.url, mediaRef: source.clip.mediaRef)
                    spans = analysis.segments.map { ($0.start, $0.end) }
                    method = .voiceActivity
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    guard allowWholeClipFallback else { throw Failure.unavailable(source.clip.mediaRef) }
                    timings.append(Timing(clipId: source.clip.id,
                                          ranges: [source.clip.startFrame..<source.clip.endFrame], method: .wholeClip))
                    continue
                }
            }
            var ranges: [Range<Int>] = []
            for (start, end) in spans {
                guard start.isFinite, end.isFinite, start >= 0, end > start else {
                    throw Failure.invalidTiming(source.clip.mediaRef)
                }
                if let range = source.clip.timelineRange(sourceStartFrame: start * Double(fps), sourceEndFrame: end * Double(fps)) {
                    ranges.append(range)
                }
            }
            timings.append(Timing(clipId: source.clip.id, ranges: ranges, method: method))
        }
        try await LoudnessAnalyzer.validateSourceVersions(versions)
        try Task.checkCancellation()
        return Result(timings: timings, sourceVersions: versions)
    }
}
