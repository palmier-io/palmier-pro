import CryptoKit
import Foundation

/// Digest of the exact timeline content a production step rendered or delivered.
///
/// Review and export bind to this digest: a delivery is verified only when the
/// exported revision equals the reviewed revision.
enum ProductionRevision {
    private struct Input: Encodable {
        let timeline: Timeline
        let children: [Timeline]
        let sources: [String: LoudnessAnalyzer.SourceVersion]
    }

    @concurrent
    static func make(
        timeline: Timeline, timelines: [Timeline], urls: [String: URL]
    ) async throws -> String {
        try Task.checkCancellation()
        let byId = Dictionary(timelines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let children = timeline.reachableTimelines(resolve: { byId[$0] }).sorted { $0.id < $1.id }
        let refs = Set(([timeline] + children).flatMap { $0.tracks.flatMap(\.clips).map(\.mediaRef) })
        let versions = try await LoudnessAnalyzer.sourceVersions(for: refs.compactMap { urls[$0] })
        var sources: [String: LoudnessAnalyzer.SourceVersion] = [:]
        for ref in refs {
            guard let url = urls[ref], let version = versions[url] else { continue }
            sources[ref] = version
        }
        try Task.checkCancellation()
        return try digest(Input(timeline: timeline, children: children, sources: sources))
    }

    /// Digest of a value, used for step idempotency keys.
    static func digest(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    /// Digest of the plan content an assembly depends on. The same plan content
    /// always yields the same key, so a resumed run never assembles twice.
    static func assemblyInputs(_ plan: EditPlan) throws -> String {
        struct Shot: Encodable {
            let id: String
            let mediaRef: String?
            let startFrame: Int
            let endFrame: Int
            let sourceStartSeconds: Double?
            let sourceEndSeconds: Double?
            let trackId: String?
            let sourceAudio: String?
        }
        struct Inputs: Encodable {
            let shots: [Shot]
            let narration: String?
            let timelineId: String
            let fps: Int
            let width: Int
            let height: Int
        }
        return try digest(Inputs(
            shots: plan.shots.map {
                Shot(id: $0.id, mediaRef: $0.mediaRef, startFrame: $0.startFrame, endFrame: $0.endFrame,
                     sourceStartSeconds: $0.sourceStartSeconds, sourceEndSeconds: $0.sourceEndSeconds,
                     trackId: $0.trackId, sourceAudio: $0.sourceAudio?.rawValue)
            },
            narration: plan.narration?.mediaRef,
            timelineId: plan.timelineId, fps: plan.fps, width: plan.width, height: plan.height))
    }
}
