import AppKit
import Foundation

enum MCPPreviewRuntime {
    @MainActor static var projectProvider: (() -> VideoProject?)?

    @MainActor
    static func context() -> [String: Any] {
        guard let editor = projectProvider?()?.editorViewModel else {
            return [:]
        }
        return [
            "playheadFrame": editor.currentFrame,
            "timelineId": editor.timeline.id,
            "fps": editor.timeline.fps,
            "totalFrames": editor.timeline.totalFrames,
        ]
    }

    @MainActor
    static func reveal(mediaRef: String) -> Bool {
        guard let editor = projectProvider?()?.editorViewModel,
              let asset = editor.mediaAssets.first(where: { $0.id == mediaRef }) else {
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        editor.selectMediaAsset(asset)
        return true
    }

    @MainActor
    static func publish(_ asset: MediaAsset) {
        guard let kind = MCPPreviewStore.Kind.from(asset.type) else { return }
        let status: String?
        let failure: String?
        switch asset.generationStatus {
        case .none:
            status = nil
            failure = nil
        case .failed(let message):
            status = asset.generationStatus.serialized
            failure = message
        default:
            status = asset.generationStatus.serialized
            failure = nil
        }
        let handle = MCPPreviewStore.AssetHandle(
            mediaRef: asset.id,
            fileURL: asset.url,
            mimeType: MCPPreviewApp.mimeType(for: asset.url, type: asset.type),
            kind: kind,
            width: asset.sourceWidth,
            height: asset.sourceHeight,
            durationSeconds: asset.duration > 0 ? asset.duration : nil,
            status: status,
            failure: failure
        )
        Task { await MCPPreviewStore.shared.publish(handle) }
    }
}
