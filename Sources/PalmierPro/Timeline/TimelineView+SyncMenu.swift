import AppKit

extension TimelineView {
    @objc func performSynchronize(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [String: Any],
              let referenceClipId = info["referenceClipId"] as? String,
              let targetClipIds = info["targetClipIds"] as? [String], !targetClipIds.isEmpty else { return }
        let mode = (info["mode"] as? String).flatMap(EditorViewModel.SyncMode.init) ?? .auto
        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await editor.syncClips(referenceClipId: referenceClipId, targetClipIds: targetClipIds, mode: mode)
            editor.mediaPanelToast = MediaPanelToast(
                message: Self.synchronizeSummary(report),
                kind: report.synced.isEmpty ? .warning : .success
            )
            needsDisplay = true
        }
    }

    private static func synchronizeSummary(_ report: EditorViewModel.SyncBatchReport) -> String {
        if report.synced.isEmpty, let first = report.failures.first {
            return report.failures.count == 1 ? first.message : "Couldn't align \(report.failures.count) clips."
        }
        let byTimecode = report.synced.count(where: { $0.method == .timecode })
        let byAudio = report.synced.count - byTimecode
        var msg = "Synchronized \(report.synced.count) clip\(report.synced.count == 1 ? "" : "s")"
        switch (byTimecode, byAudio) {
        case (0, _): msg += " by audio"
        case (_, 0): msg += " by timecode"
        default: msg += " (\(byTimecode) by timecode, \(byAudio) by audio)"
        }
        if report.shiftedFrames > 0 { msg += ", group moved right to fit" }
        if !report.failures.isEmpty { msg += "; \(report.failures.count) couldn't align" }
        return msg + "."
    }
}
