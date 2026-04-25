import AVFoundation
import AppKit

enum ExportFormat {
    case h264, h265, prores, xml

    var fileExtension: String {
        switch self {
        case .h264, .h265: "mp4"
        case .prores: "mov"
        case .xml: "xml"
        }
    }

    var utType: AVFileType? {
        switch self {
        case .h264, .h265: .mp4
        case .prores: .mov
        case .xml: nil
        }
    }
}

enum ExportResolution: String, CaseIterable, Identifiable {
    case r720p = "720p"
    case r1080p = "1080p"
    case r4k = "4K"

    var id: String { rawValue }

    /// Approximate bitrate in bytes per second for file size estimation
    var estimatedBytesPerSecond: Int {
        switch self {
        case .r720p: 625_000       // ~5 Mbps
        case .r1080p: 1_250_000    // ~10 Mbps
        case .r4k: 6_250_000       // ~50 Mbps
        }
    }
}

@Observable
@MainActor
final class ExportService {
    var progress: Double = 0
    var isExporting = false
    var error: String?

    func export(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution,
        outputURL: URL
    ) async {
        if format == .xml {
            XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outputURL)
            progress = 1.0
            return
        }

        isExporting = true
        progress = 0
        error = nil

        do {
            let result = try await CompositionBuilder.build(
                timeline: timeline,
                resolveURL: { resolver.resolveURL(for: $0) }
            )

            // AVAssetExportSession fails if the file already exists
            try? FileManager.default.removeItem(at: outputURL)

            let presetName = exportPresetName(format: format, resolution: resolution)
            guard let session = AVAssetExportSession(asset: result.composition, presetName: presetName) else {
                error = "Export preset not supported on this system"
                isExporting = false
                return
            }

            guard let fileType = format.utType else {
                error = "Invalid export format"
                isExporting = false
                return
            }

            session.audioMix = result.audioMix

            // Bake text clips into the export via AVVideoCompositionCoreAnimationTool.
            // Preview uses AVSynchronizedLayer for the same layer tree; these
            // paths cannot share a composition because AVPlayer rejects any
            // videoComposition with an animationTool set.
            let canvas = CGSize(width: timeline.width, height: timeline.height)
            let (parent, videoLayer) = TextLayerController.buildForExport(
                timeline: timeline,
                fps: timeline.fps,
                canvasSize: canvas
            )
            let mutableVC = result.videoComposition.mutableCopy() as! AVMutableVideoComposition
            mutableVC.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer,
                in: parent
            )
            session.videoComposition = mutableVC

            // Poll progress periodically
            nonisolated(unsafe) let unsafeSession = session
            let progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    let p = Double(unsafeSession.progress)
                    if p != self.progress { self.progress = p }
                }
            }

            do {
                Log.export.notice("export start format=\(String(describing: format)) resolution=\(resolution.rawValue) url=\(outputURL.lastPathComponent)")
                try await session.export(to: outputURL, as: fileType)
                progress = 1.0
                Log.export.notice("export ok")
            } catch {
                if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError {
                    self.error = "Export was cancelled"
                    Log.export.notice("export cancelled")
                } else {
                    self.error = error.localizedDescription
                    Log.export.error("export failed: \(error.localizedDescription)")
                }
            }

            progressTask.cancel()
        } catch {
            self.error = error.localizedDescription
            Log.export.error("composition build failed: \(error.localizedDescription)")
        }

        isExporting = false
    }

    // MARK: - Export preset mapping

    private func exportPresetName(format: ExportFormat, resolution: ExportResolution) -> String {
        switch format {
        case .h264:
            switch resolution {
            case .r720p: AVAssetExportPreset1280x720
            case .r1080p: AVAssetExportPreset1920x1080
            case .r4k: AVAssetExportPreset3840x2160
            }
        case .h265:
            switch resolution {
            case .r720p: AVAssetExportPresetHEVC1920x1080
            case .r1080p: AVAssetExportPresetHEVC1920x1080
            case .r4k: AVAssetExportPresetHEVC3840x2160
            }
        case .prores:
            AVAssetExportPresetAppleProRes422LPCM
        case .xml:
            AVAssetExportPresetPassthrough // unreachable — XML returns early
        }
    }
}
