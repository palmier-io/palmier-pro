import AVFoundation
import AppKit

enum ExportError: LocalizedError {
    case unsupportedPreset
    case invalidFormat
    case xmlEncodingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedPreset: "Export preset not supported on this system"
        case .invalidFormat: "Invalid export format"
        case .xmlEncodingFailed: "Couldn't encode the timeline as XML"
        }
    }
}

struct ExportRunReport {
    let outputSize: CGSize
    let offlineMediaRefs: Set<String>
    let unprocessableMediaRefs: Set<String>
}

@Observable
@MainActor
final class ExportService {
    var progress: Double = 0
    var isExporting = false
    var error: String?
    var lastReport: ExportRunReport?

    func export(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution,
        missingMediaRefs: Set<String> = [],
        outputURL: URL,
        acquireSlot: Bool = true
    ) async {
        error = nil
        lastReport = nil
        isExporting = true
        progress = 0
        defer { isExporting = false }

        if format == .xml {
            Log.export.notice(
                "export requested format=xml",
                telemetry: "Export started",
                data: ["format": "xml", "tracks": timeline.tracks.count, "clips": timeline.tracks.reduce(0) { $0 + $1.clips.count }]
            )
            do {
                try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outputURL)
                progress = 1.0
                Log.export.notice("export ok format=xml", telemetry: "Export finished", data: ["format": "xml"])
            } catch {
                self.error = Log.detail(error)
                Log.export.error(
                    "export failed format=xml: \(Log.detail(error))",
                    telemetry: "Export failed",
                    data: ["format": "xml", "error": Log.detail(error)]
                )
            }
            return
        }

        if acquireSlot {
            await ExportCoordinator.acquireExport()
        }
        defer { if acquireSlot { ExportCoordinator.endExport() } }

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
            let prepared = try await makeExportSession(
                timeline: timeline, resolver: resolver,
                format: format, resolution: resolution,
                missingMediaRefs: missingMediaRefs
            )
            let session = prepared.session
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
                try await session.export(to: outputURL, as: fileType)
                let outputSize = await Self.encodedVideoSize(of: outputURL) ?? prepared.renderSize
                lastReport = ExportRunReport(
                    outputSize: outputSize,
                    offlineMediaRefs: prepared.result.offlineMediaRefs,
                    unprocessableMediaRefs: prepared.result.unprocessableMediaRefs
                )
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

            progressTask.cancel()
        } catch {
            self.error = Log.detail(error)
            Log.export.error(
                "export setup failed: \(Log.detail(error))",
                telemetry: "Export setup failed",
                data: ["format": String(describing: format), "resolution": resolution.rawValue, "error": Log.detail(error)]
            )
        }

    }

    /// Writes a self-contained `.palmier` bundle (all media collected internally).
    @discardableResult
    func exportPalmierProject(
        timeline: Timeline,
        manifest: MediaManifest,
        generationLog: GenerationLog,
        sourceProjectURL: URL?,
        outputURL: URL,
        acquireSlot: Bool = true
    ) async -> PalmierProjectExporter.Report? {
        isExporting = true
        progress = 0
        error = nil
        lastReport = nil
        defer { isExporting = false }

        if acquireSlot {
            await ExportCoordinator.acquireExport()
        }
        defer { if acquireSlot { ExportCoordinator.endExport() } }

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

    /// Encoded dimensions of the written file (natural size with preferred
    /// transform applied), the source of truth when a preset clamped the size.
    private static func encodedVideoSize(of url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let size = naturalSize.applying(transform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    private func makeExportSession(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution,
        missingMediaRefs: Set<String>
    ) async throws -> (session: AVAssetExportSession, result: CompositionResult, renderSize: CGSize) {
        let timelineCanvas = CGSize(width: timeline.width, height: timeline.height)
        let renderSize = resolution.renderSize(for: timelineCanvas)
        let mediaURLs = resolver.expectedURLMap()

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { mediaURLs[$0] },
            missingMediaRefs: missingMediaRefs,
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
        return (session, result, renderSize)
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
            // composition's renderSize, so 2K / Match Timeline export at their true size.
            case .r1440p, .matchTimeline: AVAssetExportPresetHighestQuality
            }
        case .h265:
            switch resolution {
            case .r720p: AVAssetExportPresetHEVCHighestQuality
            case .r1080p: AVAssetExportPresetHEVC1920x1080
            case .r4k: AVAssetExportPresetHEVC3840x2160
            case .r1440p, .matchTimeline: AVAssetExportPresetHEVCHighestQuality
            }
        case .prores:
            AVAssetExportPresetAppleProRes422LPCM
        case .xml:
            AVAssetExportPresetPassthrough // unreachable — XML returns early
        }
    }
}
