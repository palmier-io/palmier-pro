import Foundation

extension ToolExecutor {
    private static let exportVideoAllowedKeys: Set<String> = ["path", "format", "resolution"]

    /// Renders the current timeline to a file on disk — the agent-facing equivalent of the
    /// File ▸ Export dialog (`ExportView.startExport`). Awaits completion and reports the path,
    /// matching how the GUI awaits `ExportService.export` and surfaces `service.error`.
    func exportVideo(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.exportVideoAllowedKeys, path: "export_video")

        let rawPath = try args.requireString("path")
        let format = try Self.exportFormat(from: args.string("format"))
        let resolution = try Self.exportResolution(from: args.string("resolution"))

        guard (rawPath as NSString).isAbsolutePath else {
            throw ToolError("path must be an absolute file path (got '\(rawPath)')")
        }
        guard editor.timeline.totalFrames > 0 else {
            throw ToolError("Timeline is empty — add clips before exporting.")
        }

        // Normalize the output extension to the chosen format so we never write,
        // e.g., a ProRes .mov under a .mp4 name.
        var outputURL = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
        if outputURL.pathExtension.lowercased() != format.fileExtension {
            outputURL.deletePathExtension()
            outputURL.appendPathExtension(format.fileExtension)
        }

        let parentDir = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        } catch {
            throw ToolError("Could not create output directory \(parentDir.path): \(error.localizedDescription)")
        }

        let service = ExportService()
        await service.export(
            timeline: editor.timeline,
            resolver: editor.mediaResolver,
            format: format,
            resolution: resolution,
            outputURL: outputURL
        )

        if let err = service.error {
            throw ToolError("Export failed: \(err)")
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ToolError("Export reported success but no file was written at \(outputURL.path)")
        }

        let bytes = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let seconds = String(format: "%.2f", Double(editor.timeline.totalFrames) / Double(max(1, editor.timeline.fps)))

        if format == .xml {
            return .ok("Wrote timeline interchange XML to \(outputURL.path) (\(sizeStr)). This is the edit only — media is not rendered; open it in Premiere/DaVinci/Final Cut.")
        }
        return .ok("Exported timeline to \(outputURL.path) (\(Self.formatLabel(format)), \(resolution.rawValue), \(sizeStr), ≈\(seconds)s).")
    }

    private static func exportFormat(from raw: String?) throws -> ExportFormat {
        switch (raw ?? "h264").lowercased() {
        case "h264", "mp4", "avc": return .h264
        case "h265", "hevc": return .h265
        case "prores", "mov": return .prores
        case "xml", "fcpxml": return .xml
        default:
            throw ToolError("Invalid format '\(raw ?? "")'. Expected 'h264', 'h265', 'prores', or 'xml'.")
        }
    }

    private static func exportResolution(from raw: String?) throws -> ExportResolution {
        switch (raw ?? "1080p").lowercased() {
        case "720p", "720": return .r720p
        case "1080p", "1080", "fhd": return .r1080p
        case "4k", "2160p", "2160", "uhd": return .r4k
        default:
            throw ToolError("Invalid resolution '\(raw ?? "")'. Expected '720p', '1080p', or '4k'.")
        }
    }

    private static func formatLabel(_ format: ExportFormat) -> String {
        switch format {
        case .h264: return "H.264"
        case .h265: return "H.265"
        case .prores: return "ProRes"
        case .xml: return "XML"
        }
    }
}
