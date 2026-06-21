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
    case r1440p = "2K"
    case r4k = "4K"
    case native = "Match Timeline"

    var id: String { rawValue }

    /// Target short-side height for the fixed presets; nil for `.native` (uses the timeline size).
    var shortSidePixels: Int? {
        switch self {
        case .r720p: 720
        case .r1080p: 1080
        case .r1440p: 1440
        case .r4k: 2160
        case .native: nil
        }
    }

    func renderSize(for canvas: CGSize) -> CGSize {
        guard let shortSidePixels else { return evenSize(canvas) }
        let canvasShort = min(canvas.width, canvas.height)
        guard canvasShort > 0 else { return canvas }
        let scale = Double(shortSidePixels) / Double(canvasShort)
        return evenSize(CGSize(width: canvas.width * scale, height: canvas.height * scale))
    }

    private func evenSize(_ size: CGSize) -> CGSize {
        let w = (Int(size.width.rounded()) / 2) * 2
        let h = (Int(size.height.rounded()) / 2) * 2
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
            Log.export.notice(
                "export requested format=xml",
                telemetry: "Export started",
                data: ["format": "xml", "tracks": timeline.tracks.count, "clips": timeline.tracks.reduce(0) { $0 + $1.clips.count }]
            )
            XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outputURL)
            progress = 1.0
            Log.export.notice("export ok format=xml", telemetry: "Export finished", data: ["format": "xml"])
            return
        }

        isExporting = true
        progress = 0
        error = nil
        defer { isExporting = false }

        guard let fileType = format.utType else {
            error = "Invalid export format"
            return
        }
        let renderSize = resolution.renderSize(for: CGSize(width: timeline.width, height: timeline.height))
        let hasText = timeline.tracks.contains { $0.clips.contains { $0.mediaType == .text } }
        let needsColor = CompositionBuilder.needsColorCompositor(timeline)

        Log.export.notice(
            "export requested format=\(String(describing: format)) resolution=\(resolution.rawValue)",
            telemetry: "Export started",
            data: [
                "format": String(describing: format),
                "resolution": resolution.rawValue,
                "tracks": timeline.tracks.count,
                "clips": timeline.tracks.reduce(0) { $0 + $1.clips.count },
                "totalFrames": timeline.totalFrames,
                "fps": timeline.fps
            ]
        )

        do {
            try? FileManager.default.removeItem(at: outputURL)
            Log.export.notice("export start format=\(String(describing: format)) resolution=\(resolution.rawValue) hasText=\(hasText) color=\(needsColor) url=\(outputURL.lastPathComponent)")

            if hasText && needsColor {
                // The Core Animation text tool and the custom colour compositor can't
                // coexist in one pass: bake colour first, then overlay text.
                let temp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("export-color-\(UUID().uuidString).\(format.fileExtension)")
                defer { try? FileManager.default.removeItem(at: temp) }

                let colorSession = try await makeExportSession(
                    timeline: timeline, resolver: resolver, format: format,
                    resolution: resolution, includeTextOverlay: false
                )
                try await runExport(colorSession, to: temp, as: fileType, progressRange: 0.0...0.5)

                let textSession = try await makeTextOverlaySession(
                    inputURL: temp, timeline: timeline, renderSize: renderSize,
                    format: format, resolution: resolution
                )
                try await runExport(textSession, to: outputURL, as: fileType, progressRange: 0.5...1.0)
            } else {
                let session = try await makeExportSession(
                    timeline: timeline, resolver: resolver, format: format,
                    resolution: resolution, includeTextOverlay: hasText
                )
                try await runExport(session, to: outputURL, as: fileType, progressRange: 0.0...1.0)
            }
            progress = 1.0
            Log.export.notice(
                "export ok",
                telemetry: "Export finished",
                data: ["format": String(describing: format), "resolution": resolution.rawValue]
            )
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError {
                self.error = "Export was cancelled"
                Log.export.notice(
                    "export cancelled",
                    telemetry: "Export cancelled",
                    data: ["format": String(describing: format), "resolution": resolution.rawValue]
                )
            } else {
                self.error = Log.detail(error)
                Log.export.error(
                    "export failed: \(Log.detail(error))",
                    telemetry: "Export failed",
                    data: ["format": String(describing: format), "resolution": resolution.rawValue, "error": Log.detail(error)]
                )
            }
        }
    }

    /// Run one export session, mapping its 0…1 progress into `progressRange`.
    private func runExport(
        _ session: AVAssetExportSession, to url: URL, as fileType: AVFileType,
        progressRange: ClosedRange<Double>
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        nonisolated(unsafe) let unsafeSession = session
        let span = progressRange.upperBound - progressRange.lowerBound
        let lower = progressRange.lowerBound
        let progressTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                let p = lower + Double(unsafeSession.progress) * span
                if p != self.progress { self.progress = p }
            }
        }
        defer { progressTask.cancel() }
        try await session.export(to: url, as: fileType)
    }

    /// Second pass: overlay the timeline's text clips onto an already-rendered video
    /// using the Core Animation tool (standard compositor, no custom compositor).
    private func makeTextOverlaySession(
        inputURL: URL, timeline: Timeline, renderSize: CGSize,
        format: ExportFormat, resolution: ExportResolution
    ) async throws -> AVAssetExportSession {
        let asset = AVURLAsset(url: inputURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: exportPresetName(format: format, resolution: resolution)) else {
            throw ExportError.unsupportedPreset
        }
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw ExportError.invalidFormat
        }
        let duration = try await asset.load(.duration)
        let (parent, videoLayer) = TextLayerController.buildForExport(
            timeline: timeline, fps: timeline.fps, renderSize: renderSize
        )

        var cfg = AVVideoComposition.Configuration()
        cfg.renderSize = renderSize
        cfg.frameDuration = CMTime(value: 1, timescale: CMTimeScale(timeline.fps))
        cfg.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        cfg.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        cfg.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        var instr = AVVideoCompositionInstruction.Configuration()
        instr.timeRange = CMTimeRange(start: .zero, duration: duration)
        instr.layerInstructions = [
            AVVideoCompositionLayerInstruction(
                configuration: AVVideoCompositionLayerInstruction.Configuration(trackID: videoTrack.trackID)
            )
        ]
        cfg.instructions = [AVVideoCompositionInstruction(configuration: instr)]
        cfg.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
        session.videoComposition = AVVideoComposition(configuration: cfg)
        return session
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
            Log.export.notice(
                "palmier export start url=\(outputURL.lastPathComponent)",
                telemetry: "Palmier project export started",
                data: [
                    "tracks": timeline.tracks.count,
                    "clips": timeline.tracks.reduce(0) { $0 + $1.clips.count },
                    "media": manifest.entries.count,
                    "generationLogEntries": generationLog.entries.count
                ]
            )
            let report = try await Task.detached(priority: .userInitiated) {
                try PalmierProjectExporter.export(
                    timeline: timeline, manifest: manifest, generationLog: generationLog,
                    sourceProjectURL: sourceProjectURL, to: outputURL,
                    progress: { p in Task { @MainActor in self.progress = p } }
                )
            }.value
            progress = 1.0
            Log.export.notice(
                "palmier export ok collected=\(report.collected.count) missing=\(report.missing.count)",
                telemetry: "Palmier project export finished",
                data: ["collected": report.collected.count, "missing": report.missing.count]
            )
            return report
        } catch {
            self.error = Log.detail(error)
            Log.export.error(
                "palmier export failed: \(Log.detail(error))",
                telemetry: "Palmier project export failed",
                data: ["error": Log.detail(error)]
            )
            return nil
        }
    }

    private func makeExportSession(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution,
        includeTextOverlay: Bool
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

        if includeTextOverlay {
            // Bake text clips via the Core Animation tool (valid only without a custom compositor).
            let (parent, videoLayer) = TextLayerController.buildForExport(
                timeline: timeline,
                fps: timeline.fps,
                renderSize: renderSize
            )
            var config = result.videoCompositionConfiguration
            config.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: videoLayer,
                in: parent
            )
            session.videoComposition = AVVideoComposition(configuration: config)
        } else {
            session.videoComposition = result.videoComposition
        }
        return session
    }

    // MARK: - Export preset mapping

    private func exportPresetName(format: ExportFormat, resolution: ExportResolution) -> String {
        switch format {
        case .h264:
            switch resolution {
            case .r720p: AVAssetExportPreset1280x720
            case .r1080p: AVAssetExportPreset1920x1080
            case .r4k: AVAssetExportPreset3840x2160
            // Size-named presets clamp dimensions; HighestQuality honours the
            // composition's renderSize, so 2K / native export at their true size.
            case .r1440p, .native: AVAssetExportPresetHighestQuality
            }
        case .h265:
            switch resolution {
            case .r720p: AVAssetExportPresetHEVC1920x1080
            case .r1080p: AVAssetExportPresetHEVC1920x1080
            case .r4k: AVAssetExportPresetHEVC3840x2160
            case .r1440p, .native: AVAssetExportPresetHEVCHighestQuality
            }
        case .prores:
            AVAssetExportPresetAppleProRes422LPCM
        case .xml:
            AVAssetExportPresetPassthrough // unreachable — XML returns early
        }
    }
}
