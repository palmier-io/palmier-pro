import AppKit

extension TimelineView {
    @objc func performDetectBeats(_ sender: Any?) {
        guard let mediaRef = (sender as? NSMenuItem)?.representedObject as? String,
              let asset = editor.mediaAssets.first(where: { $0.id == mediaRef }) else { return }
        let force = editor.mediaVisualCache.beats.analysis(for: mediaRef) != nil
        let task = editor.mediaVisualCache.beats.detect(for: asset, force: force)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let analysis = try? await task.value {
                editor.mediaPanelToast = analysis.beats.isEmpty
                    ? MediaPanelToast(message: "No beats detected.", kind: .warning)
                    : MediaPanelToast(
                        message: "Detected \(Int(analysis.bpm.rounded())) BPM, \(analysis.beats.count) beats.",
                        kind: .success
                    )
            } else {
                editor.mediaPanelToast = MediaPanelToast(
                    message: "Beat detection failed. Check that the media file is reachable, then retry.",
                    kind: .warning
                )
            }
            needsDisplay = true
        }
    }
}
