import AppKit

extension TimelineView {
    @objc func toggleMarkScenes(_ sender: Any?) {
        editor.markScenes.toggle()
    }

    @objc func performDetectScenes(_ sender: Any?) {
        guard let mediaRef = (sender as? NSMenuItem)?.representedObject as? String,
              let asset = editor.mediaAssets.first(where: { $0.id == mediaRef }) else { return }
        let force = editor.mediaVisualCache.scenes.analysis(for: mediaRef) != nil
        editor.markScenes = true
        let task = editor.mediaVisualCache.scenes.detect(for: asset, force: force)
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let analysis = try? await task.value {
                if analysis.cuts.isEmpty {
                    editor.mediaPanelToast = MediaPanelToast(message: L10n.string("No scene changes detected."), kind: .warning)
                } else {
                    editor.mediaPanelToast = MediaPanelToast(
                        message: L10n.string("Detected \(analysis.cuts.count) scene changes."),
                        kind: .success
                    )
                }
            } else {
                editor.mediaPanelToast = MediaPanelToast(
                    message: L10n.string("Scene detection failed. Check that the media file is reachable, then retry."),
                    kind: .warning
                )
            }
            needsDisplay = true
        }
    }
}
