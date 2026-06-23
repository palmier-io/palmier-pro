import AppKit

extension TimelineView {
    @objc func performSynchronize(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [String: Any],
              let referenceClipId = info["referenceClipId"] as? String,
              let targetClipIds = info["targetClipIds"] as? [String], !targetClipIds.isEmpty else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await editor.syncAudio(referenceClipId: referenceClipId, targetClipIds: targetClipIds)
            editor.mediaPanelToast = MediaPanelToast(
                message: Self.synchronizeSummary(report),
                kind: report.synced.isEmpty ? .warning : .success
            )
            needsDisplay = true
        }
    }

    private static func synchronizeSummary(_ report: EditorViewModel.AudioSyncBatchReport) -> String {
        if report.synced.isEmpty, let first = report.failures.first {
            return report.failures.count == 1 ? first.message : "Couldn't align \(report.failures.count) clips."
        }
        var msg = "Synchronized \(report.synced.count) clip\(report.synced.count == 1 ? "" : "s")"
        if !report.failures.isEmpty { msg += "; \(report.failures.count) couldn't align" }
        return msg + "."
    }
}
