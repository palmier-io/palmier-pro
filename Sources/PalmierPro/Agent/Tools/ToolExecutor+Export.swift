import Foundation

extension ToolExecutor {
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
        }

        let format = try mode == .video ? ExportFormat.videoCodec(named: input.codec) : nil
        let resolution = try mode == .video ? ExportResolution.exportPreset(named: input.resolution) : .matchTimeline

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
            guard editor.timeline.totalFrames > 0 else {
                throw ToolError("export_project: timeline is empty")
            }
            return try exportVideo(editor, format: format, resolution: resolution, outputURL: outputURL)
        case .xml:
            return try await exportXML(editor, outputURL: outputURL)
        case .palmier:
            return try await exportPalmier(editor, outputURL: outputURL)
        }
    }

    private func exportVideo(
        _ editor: EditorViewModel,
        format: ExportFormat,
        resolution: ExportResolution,
        outputURL: URL
    ) throws -> ToolResult {
        guard ExportCoordinator.beginExportIfIdle() else {
            throw ToolError("export_project: Another export is already in progress.")
        }

        let timeline = editor.timeline
        let resolver = editor.mediaResolver
        let missingMediaRefs = editor.missingMediaRefs
        let name = outputURL.lastPathComponent

        Task { @MainActor in
            defer { ExportCoordinator.endExport() }
            let service = ExportService()
            await service.export(
                timeline: timeline,
                resolver: resolver,
                format: format,
                resolution: resolution,
                missingMediaRefs: missingMediaRefs,
                outputURL: outputURL,
                acquireSlot: false
            )
            if let error = service.error {
                AppNotifications.exportFailed(name: name, reason: error)
            } else {
                let report = service.lastReport
                let warningCount = (report?.offlineMediaRefs.count ?? 0) + (report?.unprocessableMediaRefs.count ?? 0)
                AppNotifications.exportComplete(
                    name: name,
                    outputURL: outputURL,
                    size: report?.outputSize,
                    warningCount: warningCount
                )
            }
        }

        return try jsonResult([
            "status": "started",
            "mode": ExportProjectMode.video.rawValue,
            "path": outputURL.path,
            "codec": format.displayName,
            "resolution": resolution.rawValue,
            "durationFrames": editor.timeline.totalFrames,
            "durationSeconds": Double(editor.timeline.totalFrames) / Double(max(1, editor.timeline.fps)),
            "fps": editor.timeline.fps,
            "note": "Rendering in the background. A system notification will report completion or failure.",
        ])
    }

    private func exportXML(_ editor: EditorViewModel, outputURL: URL) async throws -> ToolResult {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            do {
                try FileManager.default.removeItem(at: outputURL)
            } catch {
                throw ToolError("export_project: \(error.localizedDescription)")
            }
        }
        do {
            try await XMLExporter.export(timeline: editor.timeline, resolver: editor.mediaResolver, outputURL: outputURL)
        } catch {
            throw ToolError("export_project: XML export failed: \(error.localizedDescription)")
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ToolError("export_project: XML export failed")
        }
        return try jsonResult([
            "status": "exported",
            "mode": ExportProjectMode.xml.rawValue,
            "path": outputURL.path,
            "width": editor.timeline.width,
            "height": editor.timeline.height,
            "durationFrames": editor.timeline.totalFrames,
            "durationSeconds": Double(editor.timeline.totalFrames) / Double(max(1, editor.timeline.fps)),
            "fps": editor.timeline.fps,
            "warnings": [],
        ])
    }

    private func exportPalmier(_ editor: EditorViewModel, outputURL: URL) async throws -> ToolResult {
        guard ExportCoordinator.beginExportIfIdle() else {
            throw ToolError("export_project: Another export is already in progress.")
        }
        defer { ExportCoordinator.endExport() }

        let service = ExportService()
        guard let report = await service.exportPalmierProject(
            timeline: editor.timeline,
            manifest: editor.mediaManifest,
            generationLog: editor.generationLog,
            sourceProjectURL: editor.projectURL,
            outputURL: outputURL,
            acquireSlot: false
        ) else {
            throw ToolError("export_project: \(service.error ?? "Palmier project export failed")")
        }

        let missing = report.missing.map { ["id": $0.id, "name": $0.name] }
        let warnings = missing.isEmpty
            ? []
            : ["Exported, but \(missing.count) media file\(missing.count == 1 ? "" : "s") were missing and could not be included."]

        return try jsonResult([
            "status": warnings.isEmpty ? "exported" : "exportedWithWarnings",
            "mode": ExportProjectMode.palmier.rawValue,
            "path": outputURL.path,
            "collectedMediaRefs": report.collected,
            "copiedInternalMediaCount": report.copiedInternal,
            "missingMedia": missing,
            "totalBytes": report.totalBytes,
            "warnings": warnings,
        ])
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
           !(mode == .palmier && rawExtension == expectedExtension) {
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
        guard fm.fileExists(atPath: url.path) else { return url }

        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var index = 2
        while true {
            let filename = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            let candidate = directory.appendingPathComponent(filename)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            index += 1
        }
    }

    private func jsonResult(_ payload: [String: Any]) throws -> ToolResult {
        guard let json = Self.jsonString(payload) else {
            throw ToolError("export_project: failed to encode export report")
        }
        return .ok(json)
    }
}

private struct ExportProjectArgs: DecodableToolArgs {
    static let allowedKeys: Set<String> = ["mode", "codec", "resolution", "outputPath", "overwrite"]

    var mode: String?
    var codec: String?
    var resolution: String?
    var outputPath: String?
    var overwrite: Bool?
}

private enum ExportProjectMode: String {
    case video
    case xml
    case palmier

    init(named raw: String?) throws {
        guard let raw else {
            self = .video
            return
        }
        guard let mode = Self(rawValue: raw.normalizedExportOption) else {
            throw ToolError("export_project: mode must be video, xml, or palmier")
        }
        self = mode
    }

    func fileExtension(format: ExportFormat?) -> String {
        switch self {
        case .video: format?.fileExtension ?? ExportFormat.h264.fileExtension
        case .xml: "xml"
        case .palmier: Project.fileExtension
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
        case .palmier: "Palmier Project"
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
