import Foundation

extension ToolExecutor {
    // A timeline carrying an approved managed production re-audits its current
    // output occurrences before video delivery, so manual edits or later imports
    // after approval cannot evade the no-repeat rule. Other modes carry the edit
    // itself, and untracked timelines keep the general-editing contract.
    private static func requireProductionVisualUniqueness(editor: EditorViewModel, timeline: Timeline) async throws {
        guard editor.editPlans.contains(where: { $0.timelineId == timeline.id && $0.productionRun != nil && $0.productionRun?.phase != .canceled }) else { return }
        let manifest = editor.mediaManifest
        let snapshot = timeline
        let report: VisualUniquenessReport
        do {
            report = try await VisualUniqueness.audit(timeline: snapshot, timelines: editor.timelines, manifest: manifest)
        } catch is CancellationError { throw CancellationError() }
        try Task.checkCancellation()
        guard editor.timeline(for: timeline.id) == snapshot, editor.mediaManifest == manifest else {
            throw ToolError("export_project: timeline or media changed during visual identity review; retry against current state.")
        }
        guard report.conflicts.isEmpty, report.unresolved.isEmpty else {
            throw ToolError("export_project: delivery refused — the production output repeats a visual source or has unresolved source identity (\(report.conflicts.count) conflict(s), \(report.unresolved.count) unresolved). Replace duplicates, then retry.")
        }
    }

    func manageExports(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: ManageExportsArgs = try decodeToolArgs(args, path: "manage_exports")
        let projectJobs = exportQueue.jobs(for: editor.exportQueueProjectID)

        switch input.action {
        case "wait":
            guard let rawID = input.jobId, let id = UUID(uuidString: rawID),
                  projectJobs.contains(where: { $0.id == id }) else {
                throw ToolError("manage_exports: wait requires a jobId from this project")
            }
            let job = try await exportQueue.waitForCompletion(id)
            return try jsonResult([
                "jobId": id.uuidString, "status": job.status.rawValue, "path": job.outputURL.path,
                "warnings": job.warnings, "error": job.error as Any? ?? NSNull(),
            ], tool: "manage_exports")
        case "list":
            guard input.jobId == nil else {
                throw ToolError("manage_exports: jobId only applies to cancel or wait")
            }
            let waitingIDs = exportQueue.jobs.filter { $0.status == .waiting }.map(\.id)
            let exports = projectJobs.reversed().map { job -> [String: Any] in
                var row: [String: Any] = [
                    "jobId": job.id.uuidString,
                    "filename": job.filename,
                    "path": job.outputURL.path,
                    "status": job.status.rawValue,
                    "progress": Int((job.progress * 100).rounded()),
                ]
                if let index = waitingIDs.firstIndex(of: job.id) {
                    row["queuePosition"] = index + 1
                }
                if let error = job.error {
                    row["error"] = error
                }
                if !job.warnings.isEmpty {
                    row["warnings"] = job.warnings
                }
                if let report = job.compositorReport {
                    row["result"] = report.toolPayload
                }
                return row
            }
            return try jsonResult(["exports": Array(exports)], tool: "manage_exports")
        case "cancel":
            guard let rawID = input.jobId, let id = UUID(uuidString: rawID) else {
                throw ToolError("manage_exports: cancel requires a valid jobId")
            }
            guard let job = projectJobs.first(where: { $0.id == id }) else {
                throw ToolError("manage_exports: export not found in the current project")
            }

            let responseStatus: String
            let cancellationRequested: Bool
            switch job.status {
            case .waiting:
                exportQueue.cancel(id)
                responseStatus = "removed"
                cancellationRequested = true
            case .preparing, .exporting:
                cancellationRequested = exportQueue.cancel(id)
                responseStatus = cancellationRequested ? "canceling" : job.status.rawValue
            case .canceling:
                responseStatus = "canceling"
                cancellationRequested = true
            case .completed, .failed, .canceled:
                responseStatus = job.status.rawValue
                cancellationRequested = false
            }
            return try jsonResult([
                "jobId": job.id.uuidString,
                "filename": job.filename,
                "status": responseStatus,
                "cancellationRequested": cancellationRequested,
            ], tool: "manage_exports")
        default:
            throw ToolError("manage_exports: action must be list, wait, or cancel")
        }
    }

    func exportProject(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: ExportProjectArgs = try decodeToolArgs(args, path: "export_project")
        let mode = try ExportProjectMode(named: input.mode)
        let overwrite = input.overwrite ?? true

        if mode != .video {
            if input.codec != nil {
                throw ToolError("export_project: codec only applies to video mode")
            }
            if input.resolution != nil {
                throw ToolError("export_project: resolution only applies to video mode")
            }
            if input.delivery != nil {
                throw ToolError("export_project: delivery only applies to video mode")
            }
        }
        let platform = try deliveryPlatform(input.delivery, path: "export_project.delivery")

        let timeline: Timeline
        if let id = input.timelineId {
            guard mode != .compositor else {
                throw ToolError("export_project: timelineId doesn't apply to compositor mode — the package carries every timeline")
            }
            guard let t = editor.timeline(for: id) else {
                throw ToolError("export_project: no timeline with id '\(id)'. get_timeline lists the project's timelines.")
            }
            timeline = t
        } else {
            timeline = editor.timeline
        }

        // An explicit codec or resolution always wins; `delivery` only fills the gaps, and the
        // receipt records which it did so the choice is never silent.
        let preset = mode == .video
            ? platform.exportDelivery(canvas: CGSize(width: timeline.width, height: timeline.height))
            : nil
        var deliveryNotes: [String] = []
        if let preset {
            if input.codec == nil, input.resolution == nil {
                deliveryNotes.append(
                    "delivery \(platform.rawValue) chose \(preset.codec.rawValue) at "
                        + "\(Int(preset.outputSize.width))x\(Int(preset.outputSize.height))."
                )
            }
            if let warning = preset.orientationWarning {
                deliveryNotes.append(warning)
            }
        }
        let format = try mode == .video
            ? ExportFormat.videoCodec(named: input.codec) ?? preset?.codec.exportFormat
            : nil
        let resolution = try mode == .video
            ? ExportResolution.exportPreset(named: input.resolution) ?? preset?.resolution ?? .matchTimeline
            : .matchTimeline

        let outputURL = try exportDestination(
            outputPath: input.outputPath,
            mode: mode,
            format: format,
            editor: editor,
            overwrite: overwrite
        )

        switch mode {
        case .video:
            guard let format else {
                throw ToolError("export_project: codec is required for video mode")
            }
            guard timeline.totalFrames > 0 else {
                throw ToolError("export_project: timeline is empty")
            }
            try await Self.requireProductionVisualUniqueness(editor: editor, timeline: timeline)
            return try await enqueueExport(
                editor, timeline: timeline, mode: mode, format: format,
                resolution: resolution, target: .default, outputURL: outputURL,
                deliveryNotes: deliveryNotes,
                deliveredSize: resolution.renderSize(
                    for: CGSize(width: timeline.width, height: timeline.height)
                )
            )
        case .xml:
            return try await enqueueExport(
                editor, timeline: timeline, mode: mode, format: .xml,
                resolution: .matchTimeline, target: .default, outputURL: outputURL
            )
        case .fcpxml:
            let target: FCPXMLTarget
            if let raw = input.fcpxmlTarget {
                guard let parsed = FCPXMLTarget(rawValue: raw) else {
                    throw ToolError("export_project: fcpxmlTarget must be 'resolve' or 'fcp'")
                }
                target = parsed
            } else {
                target = .default
            }
            return try await enqueueExport(
                editor, timeline: timeline, mode: mode, format: .fcpxml,
                resolution: .matchTimeline, target: target, outputURL: outputURL
            )
        case .compositor:
            return try enqueueCompositorExport(editor, outputURL: outputURL)
        }
    }

    private func enqueueExport(
        _ editor: EditorViewModel,
        timeline: Timeline,
        mode: ExportProjectMode,
        format: ExportFormat,
        resolution: ExportResolution,
        target: FCPXMLTarget,
        outputURL: URL,
        deliveryNotes: [String] = [],
        deliveredSize: CGSize? = nil
    ) async throws -> ToolResult {
        let warnings = format == .xml || format == .fcpxml
            ? nestExportWarnings(editor, timeline: timeline)
            : []

        // Wait for any pending enhancement jobs on clips in this timeline to complete
        let allClipIds = timeline.tracks.flatMap { $0.clips.map(\.id) }
        if !allClipIds.isEmpty {
            try await editor.awaitEnhancementJobsForClips(Set(allClipIds))
        }

        let submission = try exportQueue.enqueueVideo(
            timeline: timeline,
            resolver: editor.mediaResolver,
            resolveTimeline: editor.timelineResolver(),
            format: format,
            resolution: resolution,
            fcpxmlTarget: target,
            missingMediaRefs: editor.missingMediaRefs,
            outputURL: outputURL,
            source: .agent,
            projectID: editor.exportQueueProjectID,
            analyticsProjectID: editor.projectId,
            warnings: warnings
        )

        var payload: [String: Any] = [
            "status": submission.started ? "started" : "queued",
            "jobId": submission.jobID.uuidString,
            "queuePosition": submission.queuePosition,
            "mode": mode.rawValue,
            "path": outputURL.path,
            "format": format.displayName,
            "timeline": timeline.name,
            "durationFrames": timeline.totalFrames,
            "durationSeconds": Double(timeline.totalFrames) / Double(max(1, timeline.fps)),
            "fps": timeline.fps,
            "note": "The export is available in the Export dialog.",
        ]
        if let deliveredSize {
            payload["deliveredSize"] = "\(Int(deliveredSize.width))x\(Int(deliveredSize.height))"
        }
        if !deliveryNotes.isEmpty { payload["deliveryNotes"] = deliveryNotes }
        if !warnings.isEmpty { payload["warnings"] = warnings }
        return try jsonResult(payload)
    }

    private func nestExportWarnings(_ editor: EditorViewModel, timeline: Timeline) -> [String] {
        let dropped = timeline.tracks.flatMap(\.clips).count {
            $0.sourceClipType == .sequence && $0.mediaType != .audio
                && (editor.timeline(for: $0.mediaRef)?.totalFrames ?? 0) == 0
        }
        guard dropped > 0 else { return [] }
        let clips = dropped == 1 ? "clip was" : "clips were"
        return ["\(dropped) nested timeline \(clips) skipped because the source timeline is empty or missing."]
    }

    private func enqueueCompositorExport(_ editor: EditorViewModel, outputURL: URL) throws -> ToolResult {
        let submission = try exportQueue.enqueueCompositorProject(
            projectFile: editor.projectFileSnapshot(),
            manifest: editor.mediaManifest,
            sourceProjectURL: editor.projectURL,
            outputURL: outputURL,
            source: .agent,
            projectID: editor.exportQueueProjectID,
            analyticsProjectID: editor.projectId
        )

        let payload: [String: Any] = [
            "status": submission.started ? "started" : "queued",
            "jobId": submission.jobID.uuidString,
            "queuePosition": submission.queuePosition,
            "mode": ExportProjectMode.compositor.rawValue,
            "path": outputURL.path,
            "note": "The export is available in the Export dialog.",
        ]
        return try jsonResult(payload)
    }

    private func exportDestination(
        outputPath: String?,
        mode: ExportProjectMode,
        format: ExportFormat?,
        editor: EditorViewModel,
        overwrite: Bool
    ) throws -> URL {
        guard let outputPath else {
            return try downloadsExportURL(mode: mode, format: format, editor: editor)
        }

        let url = try directExportURL(outputPath, mode: mode, format: format)
        if !overwrite, FileManager.default.fileExists(atPath: url.path) {
            throw ToolError("export_project: output file already exists")
        }
        return url
    }

    private func directExportURL(_ path: String, mode: ExportProjectMode, format: ExportFormat?) throws -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            throw ToolError("export_project: outputPath must be absolute")
        }

        let fm = FileManager.default
        let rawURL = URL(fileURLWithPath: expanded)
        let expectedExtension = mode.fileExtension(format: format)
        let rawExtension = rawURL.pathExtension.lowercased()
        var url = rawURL
        if rawExtension.isEmpty {
            url.appendPathExtension(expectedExtension)
        } else if rawExtension != expectedExtension {
            throw ToolError("export_project: \(mode.label(format: format)) exports must use .\(expectedExtension)")
        }

        var isDirectory = ObjCBool(false)
        if fm.fileExists(atPath: expanded, isDirectory: &isDirectory),
           isDirectory.boolValue,
           !(mode == .compositor && rawExtension == expectedExtension) {
            throw ToolError("export_project: outputPath must include a filename")
        }

        let parent = url.deletingLastPathComponent()
        var parentIsDirectory = ObjCBool(false)
        guard fm.fileExists(atPath: parent.path, isDirectory: &parentIsDirectory), parentIsDirectory.boolValue else {
            throw ToolError("export_project: output directory does not exist")
        }
        return url.standardizedFileURL
    }

    private func downloadsExportURL(
        mode: ExportProjectMode,
        format: ExportFormat?,
        editor: EditorViewModel
    ) throws -> URL {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw ToolError("export_project: Downloads folder not found")
        }
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        return uniqueExportURL(downloads.appendingPathComponent(mode.defaultFilename(format: format, editor: editor)))
    }

    private func uniqueExportURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) || exportQueue.isDestinationReserved(url) else { return url }

        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let filename = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(filename)
            if !fm.fileExists(atPath: candidate.path), !exportQueue.isDestinationReserved(candidate) { return candidate }
            index += 1
        }
    }

    private func jsonResult(_ payload: [String: Any], tool: String = "export_project") throws -> ToolResult {
        guard let json = Self.jsonString(payload) else {
            throw ToolError("\(tool): failed to encode export report")
        }
        return .ok(json)
    }
}

private struct ManageExportsArgs: DecodableToolArgs {
    static let allowedKeys: Set<String> = ["action", "jobId"]

    let action: String
    var jobId: String?
}

private extension CompositorProjectExporter.Report {
    var toolPayload: [String: Any] {
        [
            "collectedMediaRefs": collected,
            "copiedInternalMediaCount": copiedInternal,
            "missingMedia": missing.map { ["id": $0.id, "name": $0.name] },
            "totalBytes": totalBytes,
        ]
    }
}

private struct ExportProjectArgs: DecodableToolArgs {
    static let allowedKeys: Set<String> = [
        "mode", "codec", "resolution", "delivery", "outputPath", "overwrite", "fcpxmlTarget",
        "timelineId",
    ]

    var mode: String?
    var codec: String?
    var resolution: String?
    var delivery: String?
    var outputPath: String?
    var overwrite: Bool?
    var fcpxmlTarget: String?
    var timelineId: String?
}

private enum ExportProjectMode: String {
    case video
    case xml
    case fcpxml
    case compositor

    init(named raw: String?) throws {
        guard let raw else {
            self = .video
            return
        }
        let normalized = raw == "palmier" ? ExportProjectMode.compositor.rawValue : raw
        guard let mode = Self(rawValue: normalized.normalizedExportOption) else {
            throw ToolError("export_project: mode must be video, xml, fcpxml, or compositor")
        }
        self = mode
    }

    func fileExtension(format: ExportFormat?) -> String {
        switch self {
        case .video: format?.fileExtension ?? ExportFormat.h264.fileExtension
        case .xml: "xml"
        case .fcpxml: "fcpxml"
        case .compositor: Project.fileExtension
        }
    }

    @MainActor
    func defaultFilename(format: ExportFormat?, editor: EditorViewModel) -> String {
        let base = editor.projectURL?.deletingPathExtension().lastPathComponent ?? Project.defaultProjectName
        return "\(base).\(fileExtension(format: format))"
    }

    func label(format: ExportFormat?) -> String {
        switch self {
        case .video: format?.displayName ?? "Video"
        case .xml: "XML"
        case .fcpxml: "FCPXML"
        case .compositor: "Compositor Project"
        }
    }
}

private extension ExportFormat {
    static func videoCodec(named raw: String?) throws -> ExportFormat {
        guard let raw else { return .h264 }
        switch raw.normalizedExportOption {
        case "h.264", "h264": return VideoCodec.h264.exportFormat
        case "h.265", "h265", "hevc": return VideoCodec.h265.exportFormat
        case "prores": return VideoCodec.prores.exportFormat
        default:
            throw ToolError("export_project: codec must be H.264, H.265, or ProRes")
        }
    }
}

private extension ExportResolution {
    static func exportPreset(named raw: String?) throws -> ExportResolution {
        guard let raw else { return .matchTimeline }
        switch raw.normalizedExportOption {
        case "720p": return .r720p
        case "1080p": return .r1080p
        case "2k": return .r1440p
        case "4k": return .r4k
        case "matchtimeline": return .matchTimeline
        default:
            throw ToolError("export_project: resolution must be 720p, 1080p, 2K, 4K, or Match Timeline")
        }
    }
}

private extension String {
    var normalizedExportOption: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines).joined()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
    }
}
