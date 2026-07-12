import AVFoundation
import AppKit
import CoreImage

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

struct ExportAnalyticsContext {
    var source: String = "manual"
    var projectId: String?
}

private struct ExportAnalyticsRun {
    private let basePayload: [String: Any]
    private let started: ContinuousClock.Instant

    init(
        mode: String,
        format: ExportFormat,
        resolution: ExportResolution?,
        context: ExportAnalyticsContext
    ) {
        self.basePayload = [
            "source": context.source,
            "project_id": context.projectId ?? "unknown",
            "mode": mode,
            "format": format.displayName,
            "resolution": resolution?.rawValue ?? "n/a",
        ]
        self.started = ContinuousClock.now
    }

    init(palmierContext context: ExportAnalyticsContext) {
        self.basePayload = [
            "source": context.source,
            "project_id": context.projectId ?? "unknown",
            "mode": "palmier",
            "format": "Palmier",
        ]
        self.started = ContinuousClock.now
    }

    func begin() {
        Analytics.capture(.exportStarted, properties: basePayload)
    }

    func finish() {
        Analytics.capture(.exportFinished, properties: timedPayload())
    }

    func fail() {
        Analytics.capture(.exportFailed, properties: timedPayload())
    }

    private func timedPayload() -> [String: Any] {
        var payload = basePayload
        payload["export_duration_seconds"] = Self.durationSeconds(since: started)
        return payload
    }

    private static func durationSeconds(since started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}

@MainActor
final class ExportService {
    enum Phase {
        case preparing
        case exporting
    }

    var progress: Double = 0
    var error: String?
    var lastReport: ExportRunReport?
    var lastPalmierReport: PalmierProjectExporter.Report?
    var wasCancelled = false
    private(set) var didCommitOutput = false
    var onPhaseChange: ((Phase) -> Void)?
    var onProgressChange: ((Double) -> Void)?
    private var activeCancellation: (() -> Void)?

    private enum SessionObservationPhase {
        case pending
        case started
        case ended
    }

    @discardableResult
    func cancel() -> Bool {
        guard !didCommitOutput else { return false }
        wasCancelled = true
        activeCancellation?()
        return true
    }

    func export(
        timeline: Timeline,
        resolver: MediaResolver,
        resolveTimeline: @escaping @Sendable (String) -> Timeline? = { _ in nil },
        format: ExportFormat,
        resolution: ExportResolution,
        fcpxmlVersion: FCPXMLVersion = .default,
        fcpxmlTarget: FCPXMLTarget = .default,
        missingMediaRefs: Set<String> = [],
        outputURL: URL,
        analyticsContext: ExportAnalyticsContext = .init()
    ) async {
        reset()
        defer { activeCancellation = nil }

        if format == .xml || format == .fcpxml {
            let name = format.fileExtension
            let analytics = ExportAnalyticsRun(
                mode: name,
                format: format,
                resolution: nil,
                context: analyticsContext
            )
            analytics.begin()
            setPhase(.exporting)
            Log.export.notice(
                "export requested format=\(name)",
                telemetry: "Export started",
                data: ["format": name, "tracks": timeline.tracks.count, "clips": timeline.tracks.reduce(0) { $0 + $1.clips.count }]
            )
            do {
                try await withStagedOutput(to: outputURL) { stagingURL in
                    if format == .xml {
                        try await XMLExporter.export(timeline: timeline, resolver: resolver, resolveTimeline: resolveTimeline, outputURL: stagingURL)
                    } else {
                        try await FCPXMLExporter.export(timeline: timeline, resolver: resolver, resolveTimeline: resolveTimeline,
                                                        version: fcpxmlVersion, target: fcpxmlTarget, outputURL: stagingURL)
                    }
                }
                setProgress(1)
                Log.export.notice("export ok format=\(name)", telemetry: "Export finished", data: ["format": name])
                analytics.finish()
            } catch {
                if Self.isCancellation(error) {
                    wasCancelled = true
                    Log.export.notice("export cancelled format=\(name)", telemetry: "Export cancelled", data: ["format": name])
                } else {
                    self.error = Log.detail(error)
                    Log.export.error(
                        "export failed format=\(name): \(Log.detail(error))",
                        telemetry: "Export failed",
                        data: ["format": name, "error": Log.detail(error)]
                    )
                    analytics.fail()
                }
            }
            return
        }
        let videoAnalytics = ExportAnalyticsRun(
            mode: "video",
            format: format,
            resolution: resolution,
            context: analyticsContext
        )
        if format.isHDR {
            videoAnalytics.begin()
            await exportHDR(
                timeline: timeline,
                resolver: resolver,
                resolution: resolution,
                missingMediaRefs: missingMediaRefs,
                outputURL: outputURL,
                analytics: videoAnalytics
            )
            return
        }

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
        videoAnalytics.begin()

        do {
            try checkCancellation()
            let prepared = try await makeExportSession(
                timeline: timeline, resolver: resolver, resolveTimeline: resolveTimeline,
                format: format, resolution: resolution,
                missingMediaRefs: missingMediaRefs
            )
            let session = prepared.session
            guard let fileType = format.utType else { throw ExportError.invalidFormat }
            nonisolated(unsafe) let unsafeSession = session
            try await withStagedOutput(to: outputURL) { stagingURL in
                var observationPhase = SessionObservationPhase.pending
                let stateTask = Task { @MainActor in
                    defer { observationPhase = .ended }
                    for await state in unsafeSession.states(updateInterval: 0.2) {
                        switch state {
                        case .pending:
                            break
                        case .waiting:
                            observationPhase = .started
                        case .exporting(let progress):
                            observationPhase = .started
                            setProgress(progress.fractionCompleted)
                        @unknown default:
                            break
                        }
                    }
                }
                defer { stateTask.cancel() }

                let exportTask = Task { @MainActor in
                    try await session.export(to: stagingURL, as: fileType)
                }
                try await withTaskCancellationHandler {
                    while observationPhase == .pending {
                        try Task.checkCancellation()
                        await Task.yield()
                    }
                    let canCancelSession = observationPhase == .started
                    activeCancellation = {
                        exportTask.cancel()
                        if canCancelSession { unsafeSession.cancelExport() }
                    }
                    setPhase(.exporting)
                    try await exportTask.value
                } onCancel: {
                    exportTask.cancel()
                }
            }
            let outputSize = await Self.encodedVideoSize(of: outputURL) ?? prepared.renderSize
            lastReport = ExportRunReport(
                outputSize: outputSize,
                offlineMediaRefs: prepared.result.offlineMediaRefs,
                unprocessableMediaRefs: prepared.result.unprocessableMediaRefs
            )
            setProgress(1)
            Log.export.notice(
                "export ok",
                telemetry: "Export finished",
                data: ["format": String(describing: format), "resolution": resolution.rawValue]
            )
            videoAnalytics.finish()
        } catch {
            if Self.isCancellation(error) {
                wasCancelled = true
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
                videoAnalytics.fail()
            }
        }
    }

    /// Writes a self-contained `.palmier` bundle (all media collected internally).
    @discardableResult
    func exportPalmierProject(
        projectFile: ProjectFile,
        manifest: MediaManifest,
        generationLog: GenerationLog,
        sourceProjectURL: URL?,
        outputURL: URL,
        analyticsContext: ExportAnalyticsContext = .init()
    ) async -> PalmierProjectExporter.Report? {
        reset()
        defer { activeCancellation = nil }
        let analytics = ExportAnalyticsRun(palmierContext: analyticsContext)

        do {
            try checkCancellation()
            analytics.begin()
            setPhase(.exporting)
            Log.export.notice(
                "palmier export start url=\(outputURL.lastPathComponent)",
                telemetry: "Palmier project export started",
                data: [
                    "timelines": projectFile.timelines.count,
                    "clips": projectFile.timelines.reduce(0) { $0 + $1.tracks.reduce(0) { $0 + $1.clips.count } },
                    "media": manifest.entries.count,
                    "generationLogEntries": generationLog.entries.count
                ]
            )
            let worker = Task.detached(priority: .userInitiated) {
                try PalmierProjectExporter.export(
                    projectFile: projectFile, manifest: manifest, generationLog: generationLog,
                    sourceProjectURL: sourceProjectURL, to: outputURL,
                    progress: { p in Task { @MainActor in self.setProgress(p) } }
                )
            }
            activeCancellation = { worker.cancel() }
            let report = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
            lastPalmierReport = report
            didCommitOutput = true
            setProgress(1)
            Log.export.notice(
                "palmier export ok collected=\(report.collected.count) missing=\(report.missing.count)",
                telemetry: "Palmier project export finished",
                data: ["collected": report.collected.count, "missing": report.missing.count]
            )
            analytics.finish()
            return report
        } catch {
            if Self.isCancellation(error) {
                wasCancelled = true
                Log.export.notice("palmier export cancelled", telemetry: "Export cancelled")
            } else {
                self.error = Log.detail(error)
                Log.export.error(
                    "palmier export failed: \(Log.detail(error))",
                    telemetry: "Palmier project export failed",
                    data: ["error": Log.detail(error)]
                )
                analytics.fail()
            }
            return nil
        }
    }

    /// Encode HEVC Main10 HDR; `HDRVideoExporter` converts the composition's SDR 709 frames to HLG.
    private func exportHDR(
        timeline: Timeline,
        resolver: MediaResolver,
        resolution: ExportResolution,
        missingMediaRefs: Set<String>,
        outputURL: URL,
        analytics: ExportAnalyticsRun
    ) async {
        do {
            try checkCancellation()
            let renderSize = resolution.renderSize(for: CGSize(width: timeline.width, height: timeline.height))
            let result = try await CompositionBuilder.build(
                timeline: timeline,
                resolveURL: { resolver.resolveURL(for: $0) },
                missingMediaRefs: missingMediaRefs,
                renderSize: renderSize
            )
            try checkCancellation()
            try await withStagedOutput(to: outputURL) { stagingURL in
                Log.export.notice("hdr export start size=\(Int(renderSize.width))x\(Int(renderSize.height)) url=\(outputURL.lastPathComponent)")
                let inputs = HDRVideoExporter.Inputs(
                    composition: result.composition,
                    videoComposition: result.videoComposition,
                    audioMix: result.audioMix
                )
                setPhase(.exporting)
                try await HDRVideoExporter.export(
                    inputs, renderSize: renderSize, transfer: .hlg, to: stagingURL,
                    onProgress: { [weak self] p in Task { @MainActor in self?.setProgress(p) } }
                )
            }
            let outputSize = await Self.encodedVideoSize(of: outputURL) ?? renderSize
            lastReport = ExportRunReport(
                outputSize: outputSize,
                offlineMediaRefs: result.offlineMediaRefs,
                unprocessableMediaRefs: result.unprocessableMediaRefs
            )
            setProgress(1)
            Log.export.notice("hdr export ok")
            analytics.finish()
        } catch {
            if Self.isCancellation(error) {
                wasCancelled = true
                Log.export.notice("hdr export cancelled", telemetry: "Export cancelled")
            } else {
                self.error = Log.detail(error)
                Log.export.error("hdr export failed: \(Log.detail(error))")
                analytics.fail()
            }
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

    private func setPhase(_ phase: Phase) {
        onPhaseChange?(phase)
    }

    private func reset() {
        error = nil
        lastReport = nil
        lastPalmierReport = nil
        didCommitOutput = false
        setProgress(0)
        setPhase(.preparing)
    }

    private func setProgress(_ value: Double) {
        progress = value
        onProgressChange?(value)
    }

    private func withStagedOutput<T>(
        to outputURL: URL,
        operation: (URL) async throws -> T
    ) async throws -> T {
        try checkCancellation()
        let stagingURL = Self.stagingURL(for: outputURL)
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        let result = try await operation(stagingURL)
        try checkCancellation()
        try Self.commit(stagingURL: stagingURL, to: outputURL)
        didCommitOutput = true
        return result
    }

    private func checkCancellation() throws {
        if wasCancelled { throw CancellationError() }
        try Task.checkCancellation()
    }

    private static func stagingURL(for outputURL: URL) -> URL {
        let ext = outputURL.pathExtension
        let stem = outputURL.deletingPathExtension().lastPathComponent
        let name = ext.isEmpty
            ? ".\(stem)-\(UUID().uuidString).partial"
            : ".\(stem)-\(UUID().uuidString).partial.\(ext)"
        return outputURL.deletingLastPathComponent().appendingPathComponent(name)
    }

    private static func commit(stagingURL: URL, to outputURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputURL.path) {
            _ = try fm.replaceItemAt(outputURL, withItemAt: stagingURL)
        } else {
            try fm.moveItem(at: stagingURL, to: outputURL)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError || Task.isCancelled { return true }
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    private func makeExportSession(
        timeline: Timeline,
        resolver: MediaResolver,
        resolveTimeline: @escaping @Sendable (String) -> Timeline? = { _ in nil },
        format: ExportFormat,
        resolution: ExportResolution,
        missingMediaRefs: Set<String>
    ) async throws -> (session: AVAssetExportSession, result: CompositionResult, renderSize: CGSize) {
        let timelineCanvas = CGSize(width: timeline.width, height: timeline.height)
        let renderSize = resolution.renderSize(for: timelineCanvas)
        let mediaURLs = resolver.expectedURLMap()

        for track in timeline.tracks {
            for clip in track.clips where clip.hasDenoiseEnabled && clip.denoiseAmount > 0 {
                try Task.checkCancellation()
                guard !missingMediaRefs.contains(clip.mediaRef), let url = mediaURLs[clip.mediaRef] else { continue }
                do {
                    _ = try await AudioEnhancer.denoisedAudio(for: url, mediaRef: clip.mediaRef)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.export.error("denoise bake failed — exporting original audio. mediaRef=\(clip.mediaRef): \(Log.detail(error))")
                }
            }
        }

        try Task.checkCancellation()
        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { mediaURLs[$0] },
            resolveTimeline: resolveTimeline,
            missingMediaRefs: missingMediaRefs,
            renderSize: renderSize
        )
        try Task.checkCancellation()

        let presetName = exportPresetName(format: format, resolution: resolution)
        guard let session = AVAssetExportSession(asset: result.composition, presetName: presetName) else {
            throw ExportError.unsupportedPreset
        }
        session.audioMix = result.audioMix
        session.videoComposition = result.videoComposition
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
        case .xml, .fcpxml, .hevcHDR:
            AVAssetExportPresetPassthrough // unreachable — timeline formats and HDR return early
        }
    }
}
