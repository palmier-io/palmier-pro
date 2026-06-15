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

    var shortSidePixels: Int {
        switch self {
        case .r720p: 720
        case .r1080p: 1080
        case .r4k: 2160
        }
    }

    func renderSize(for canvas: CGSize) -> CGSize {
        let canvasShort = min(canvas.width, canvas.height)
        guard canvasShort > 0 else { return canvas }
        let scale = Double(shortSidePixels) / Double(canvasShort)
        let w = (Int((canvas.width * scale).rounded()) / 2) * 2
        let h = (Int((canvas.height * scale).rounded()) / 2) * 2
        return CGSize(width: max(2, w), height: max(2, h))
    }
}

enum ExportError: LocalizedError {
    case unsupportedPreset
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedPreset: "Export preset not supported on this system"
        case .invalidFormat: "Invalid export format"
        }
    }
}

@Observable
@MainActor
final class ExportService {
    var progress: Double = 0
    var isExporting = false {
        didSet {
            guard isExporting != oldValue else { return }
            isExporting ? SearchIndexCoordinator.exportDidBegin() : SearchIndexCoordinator.exportDidEnd()
        }
    }
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
            let session = try await makeExportSession(
                timeline: timeline, resolver: resolver,
                format: format, resolution: resolution
            )
            guard let fileType = format.utType else { throw ExportError.invalidFormat }

            // AVAssetExportSession fails if the file already exists
            try? FileManager.default.removeItem(at: outputURL)

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
                    self.error = Self.detailedMessage(for: error)
                    Log.export.error("export failed: \(Self.detailedMessage(for: error))")
                }
            }

            progressTask.cancel()
        } catch {
            self.error = Self.detailedMessage(for: error)
            Log.export.error("export setup failed: \(Self.detailedMessage(for: error))")
        }

        isExporting = false
    }

    /// Writes a self-contained `.palmier` bundle (all media collected internally).
    @discardableResult
    func exportPalmierProject(
        timeline: Timeline,
        manifest: MediaManifest,
        generationLog: GenerationLog,
        sourceProjectURL: URL?,
        outputURL: URL
    ) async -> PalmierProjectExporter.Report? {
        isExporting = true
        progress = 0
        error = nil
        defer { isExporting = false }

        do {
            Log.export.notice("palmier export start url=\(outputURL.lastPathComponent)")
            let report = try await Task.detached(priority: .userInitiated) {
                try PalmierProjectExporter.export(
                    timeline: timeline, manifest: manifest, generationLog: generationLog,
                    sourceProjectURL: sourceProjectURL, to: outputURL,
                    progress: { p in Task { @MainActor in self.progress = p } }
                )
            }.value
            progress = 1.0
            Log.export.notice("palmier export ok collected=\(report.collected.count) missing=\(report.missing.count)")
            return report
        } catch {
            self.error = Self.detailedMessage(for: error)
            Log.export.error("palmier export failed: \(Self.detailedMessage(for: error))")
            return nil
        }
    }

    private func makeExportSession(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution
    ) async throws -> AVAssetExportSession {
        let timelineCanvas = CGSize(width: timeline.width, height: timeline.height)
        let renderSize = resolution.renderSize(for: timelineCanvas)

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { resolver.resolveURL(for: $0) },
            renderSize: renderSize
        )

        let presetName = exportPresetName(format: format, resolution: resolution)
        guard let session = AVAssetExportSession(asset: result.composition, presetName: presetName) else {
            throw ExportError.unsupportedPreset
        }
        session.audioMix = result.audioMix

        // Bake text clips into the export via AVVideoCompositionCoreAnimationTool
        let (parent, videoLayer) = TextLayerController.buildForExport(
            timeline: timeline,
            fps: timeline.fps,
            renderSize: renderSize
        )
        let mutableVC = result.videoComposition.mutableCopy() as! AVMutableVideoComposition
        mutableVC.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parent
        )
        session.videoComposition = mutableVC
        return session
    }

    private static func detailedMessage(for error: Error) -> String {
        let ns = error as NSError
        var message = ns.localizedDescription
        if let reason = ns.localizedFailureReason, !message.contains(reason) {
            message += " — \(reason)"
        }
        var codes: [String] = []
        var current: NSError? = ns
        while let e = current {
            codes.append("\(e.domain) \(e.code)")
            current = e.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "\(message) (\(codes.joined(separator: " → ")))"
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
