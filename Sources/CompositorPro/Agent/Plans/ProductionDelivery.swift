import Foundation

/// Shared delivery checks for a production timeline.
///
/// The agent's export tool and the production coordinator both deliver the same
/// timeline, so the refusal rule lives here instead of in either caller.
enum ProductionDelivery {
    /// A timeline carrying an approved managed production re-audits its current
    /// output occurrences before video delivery, so manual edits or later imports
    /// after approval cannot evade the no-repeat rule. Other timelines keep the
    /// general editing contract.
    @MainActor
    static func requireVisualUniqueness(editor: EditorViewModel, timeline: Timeline) async throws {
        guard editor.editPlans.contains(where: {
            $0.timelineId == timeline.id && $0.productionRun != nil && $0.productionRun?.phase != .canceled
        }) else { return }
        let manifest = editor.mediaManifest
        let snapshot = timeline
        let report: VisualUniquenessReport
        do {
            report = try await VisualUniqueness.audit(timeline: snapshot, timelines: editor.timelines, manifest: manifest)
        } catch is CancellationError { throw CancellationError() }
        try Task.checkCancellation()
        guard editor.timeline(for: timeline.id) == snapshot, editor.mediaManifest == manifest else {
            throw ProductionError.invalidState(
                "Timeline or media changed during visual identity review; retry against current state.")
        }
        guard report.conflicts.isEmpty, report.unresolved.isEmpty else {
            throw ProductionError.invalidState(
                "delivery refused — the production output repeats a visual source or has unresolved source identity "
                + "(\(report.conflicts.count) conflict(s), \(report.unresolved.count) unresolved).")
        }
    }
}
