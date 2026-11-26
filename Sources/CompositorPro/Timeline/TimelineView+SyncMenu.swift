import AppKit

extension TimelineView {
    @objc func performSynchronize(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [String: Any],
              let referenceClipId = info["referenceClipId"] as? String,
              let targetClipIds = info["targetClipIds"] as? [String], !targetClipIds.isEmpty else { return }
        let mode = (info["mode"] as? String).flatMap(EditorViewModel.SyncMode.init) ?? .auto
        Task { @MainActor [weak self] in
            guard let self else { return }
            editor.mediaPanelToast = MediaPanelToast(message: L10n.string("Synchronizing…"), kind: .progress)
            do {
                let report = try await editor.syncClips(referenceClipId: referenceClipId, targetClipIds: targetClipIds, mode: mode)
                editor.mediaPanelToast = MediaPanelToast(
                    message: Self.synchronizeSummary(report),
                    kind: report.synced.isEmpty ? .warning : .success
                )
            } catch is CancellationError {
                editor.dismissMediaPanelToast()
            } catch {
                editor.mediaPanelToast = MediaPanelToast(message: error.localizedDescription, kind: .warning)
            }
            needsDisplay = true
        }
    }

    private static func synchronizeSummary(_ report: EditorViewModel.SyncBatchReport) -> String {
        if report.synced.isEmpty, let first = report.failures.first {
            return report.failures.count == 1
                ? first.message
                : L10n.string("Couldn't align \(report.failures.count) clips.")
        }
        let byTimecode = report.synced.count(where: { $0.method == .timecode })
        let byAudio = report.synced.count - byTimecode
        let summary = report.synced.count == 1
            ? L10n.string("Synchronized 1 clip")
            : L10n.string("Synchronized \(report.synced.count) clips")
        var details: [String] = []
        switch (byTimecode, byAudio) {
        case (0, _): details.append(L10n.string("by audio"))
        case (_, 0): details.append(L10n.string("by timecode"))
        default: details.append(L10n.string("\(byTimecode) by timecode, \(byAudio) by audio"))
        }
        if report.shiftedFrames > 0 { details.append(L10n.string("group moved right to fit")) }
        if !report.retimed.isEmpty { details.append(L10n.string("drift-corrected")) }
        if !report.retimeSkipped.isEmpty {
            details.append(L10n.string("drift correction skipped — it would overwrite an adjacent clip"))
        }
        if !report.failures.isEmpty { details.append(L10n.string("\(report.failures.count) couldn't align")) }
        return L10n.string("\(summary): \(details.joined(separator: ", ")).")
    }
}
