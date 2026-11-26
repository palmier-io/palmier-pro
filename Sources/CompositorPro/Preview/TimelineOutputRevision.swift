import CryptoKit
import Foundation

enum TimelineOutputRevision {
    private struct Input: Encodable {
        let processingVersion = 1
        let timeline: Timeline
        let children: [Timeline]
        let sources: [String: LoudnessAnalyzer.SourceVersion]
    }

    @concurrent
    static func make(
        timeline: Timeline, timelines: [Timeline], sources: [String: LoudnessAnalyzer.SourceVersion]
    ) async throws -> String {
        try Task.checkCancellation()
        var root = timeline
        root.audioMix = nil
        let byId = Dictionary(timelines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let children = root.reachableTimelines(resolve: { byId[$0] }).sorted { $0.id < $1.id }.map { child in
            var value = child
            value.audioMix = nil
            return value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Input(timeline: root, children: children, sources: sources))
        try Task.checkCancellation()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
