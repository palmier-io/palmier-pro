// Cooperative preemption between interactive transcript reads and background indexing.
// Interactive tools (get_transcript, inspect_media, add_captions) bracket their transcription
// with beginRead/endRead; the background search indexer calls waitUntilIdle between items so an
// interactive read is never stuck behind a long background transcription queue on the qwen3 actor.
import Foundation

@MainActor
final class BackgroundTranscriptionGate {
    static let shared = BackgroundTranscriptionGate()

    private var pendingReads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var hasPendingReads: Bool { pendingReads > 0 }

    func beginRead() { pendingReads += 1 }

    func endRead() {
        pendingReads = max(0, pendingReads - 1)
        guard pendingReads == 0, !waiters.isEmpty else { return }
        let resuming = waiters
        waiters.removeAll()
        for continuation in resuming { continuation.resume() }
    }

    /// Suspends the caller (the background indexer) while any interactive read is in flight.
    /// Re-checks after each wake so a read that arrives during the gap still holds the gate.
    func waitUntilIdle() async {
        while pendingReads > 0 {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    /// Brackets an interactive read so background transcription yields to it. Always balances
    /// endRead, even on throw, so a failed read can't wedge the indexer permanently.
    func read<T>(_ body: () async throws -> T) async rethrows -> T {
        beginRead()
        do {
            let result = try await body()
            endRead()
            return result
        } catch {
            endRead()
            throw error
        }
    }
}
