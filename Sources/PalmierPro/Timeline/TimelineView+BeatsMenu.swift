import AppKit

extension TimelineView {
    @objc func toggleMarkBeats(_ sender: Any?) {
        editor.markBeats.toggle()
    }

    @objc func performDetectBeats(_ sender: Any?) {
        guard let mediaRef = (sender as? NSMenuItem)?.representedObject as? String,
              let asset = editor.mediaAssets.first(where: { $0.id == mediaRef }) else { return }
        let force = editor.mediaVisualCache.beats.analysis(for: mediaRef) != nil
        editor.markBeats = true
        let task = editor.mediaVisualCache.beats.detect(for: asset, force: force)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let analysis = try? await task.value {
                if analysis.beats.isEmpty && analysis.downbeats.isEmpty {
                    editor.mediaPanelToast = MediaPanelToast(message: L10n.string("No beats detected."), kind: .warning)
                } else {
                    let count = max(analysis.beats.count, analysis.downbeats.count)
                    let message = analysis.bpm > 0
                        ? L10n.string("Detected \(count) beats at \(Int(analysis.bpm.rounded())) BPM.")
                        : L10n.string("Detected \(count) beats.")
                    editor.mediaPanelToast = MediaPanelToast(message: message, kind: .success)
                }
            } else {
                editor.mediaPanelToast = MediaPanelToast(
                    message: L10n.string("Beat detection failed. Check that the media file is reachable, then retry."),
                    kind: .warning
                )
            }
            needsDisplay = true
        }
    }
}
