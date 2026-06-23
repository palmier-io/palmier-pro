import CoreGraphics
import Foundation

extension ToolExecutor {
    private enum TimelineExportFormat: String {
        case h264, h265, prores, xml, palmierProject

        var fileExtension: String {
            switch self {
            case .h264, .h265: "mp4"
            case .prores: "mov"
            case .xml: "xml"
            case .palmierProject: Project.fileExtension
            }
        }

        var videoFormat: ExportFormat? {
            switch self {
            case .h264: .h264
            case .h265: .h265
            case .prores: .prores
            case .xml: .xml
            case .palmierProject: nil
            }
        }
    }

    func exportTimeline(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["outputPath", "format", "resolution", "overwrite"], path: "export_timeline")

        let outputPath = try args.requireString("outputPath").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !outputPath.isEmpty else {
            throw ToolError("Missing required argument: outputPath")
        }

        let format = try Self.parseTimelineExportFormat(args.string("format") ?? "h264")
        let resolution = try Self.parseExportResolution(args.string("resolution") ?? "1080p")
        let overwrite = args.bool("overwrite") ?? false
        let outputURL = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath)
        let fm = FileManager.default

        try Self.validateExportDestination(outputURL, format: format, overwrite: overwrite, fm: fm)

        if format != .xml, format != .palmierProject, editor.timeline.totalFrames <= 0 {
            throw ToolError("Timeline has no frames to export.")
        }

        let service = ExportService()
        switch format {
        case .palmierProject:
            guard await service.exportPalmierProject(
                timeline: editor.timeline,
                manifest: editor.mediaManifest,
                generationLog: editor.generationLog,
                sourceProjectURL: editor.projectURL,
                outputURL: outputURL
            ) != nil else {
                throw ToolError(service.error ?? "Export failed.")
            }
        case .h264, .h265, .prores, .xml:
            guard let videoFormat = format.videoFormat else {
                throw ToolError("Unsupported export format: \(format.rawValue)")
            }
            await service.export(
                timeline: editor.timeline,
                resolver: editor.mediaResolver,
                format: videoFormat,
                resolution: resolution,
                outputURL: outputURL
            )
            if let error = service.error {
                throw ToolError(error)
            }
        }

        guard fm.fileExists(atPath: outputURL.path) else {
            throw ToolError("Export did not create output file: \(outputURL.path)")
        }

        let canvas = CGSize(width: editor.timeline.width, height: editor.timeline.height)
        let outputSize = format.videoFormat == nil || format == .xml ? canvas : resolution.renderSize(for: canvas)
        var payload: [String: Any] = [
            "outputPath": outputURL.path,
            "format": format.rawValue,
            "width": Int(outputSize.width.rounded()),
            "height": Int(outputSize.height.rounded()),
            "fps": editor.timeline.fps,
            "totalFrames": editor.timeline.totalFrames,
            "durationSeconds": editor.timeline.fps > 0 ? Double(editor.timeline.totalFrames) / Double(editor.timeline.fps) : 0,
        ]
        if format != .xml, format != .palmierProject {
            payload["resolution"] = Self.normalizedResolutionName(resolution)
        }
        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) else {
            throw ToolError("Failed to encode export metadata")
        }
        return .ok(json)
    }

    private static func parseTimelineExportFormat(_ raw: String) throws -> TimelineExportFormat {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch normalized.lowercased() {
        case "h264", "h.264": return .h264
        case "h265", "h.265", "hevc": return .h265
        case "prores", "prores422": return .prores
        case "xml", "xmeml": return .xml
        case "palmierproject", "palmier_project", "palmier-project", "palmier": return .palmierProject
        default:
            throw ToolError("Unsupported format '\(raw)'. Expected h264, h265, prores, xml, or palmierProject.")
        }
    }

    private static func parseExportResolution(_ raw: String) throws -> ExportResolution {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "720p": return .r720p
        case "1080p": return .r1080p
        case "1440p", "2k": return .r1440p
        case "4k", "2160p": return .r4k
        case "native", "match timeline", "matchtimeline": return .native
        default:
            throw ToolError("Unsupported resolution '\(raw)'. Expected 720p, 1080p, 1440p, 4k, or native.")
        }
    }

    private static func validateExportDestination(
        _ outputURL: URL,
        format: TimelineExportFormat,
        overwrite: Bool,
        fm: FileManager
    ) throws {
        guard outputURL.isFileURL else {
            throw ToolError("outputPath must be a file path.")
        }
        guard outputURL.pathExtension.lowercased() == format.fileExtension.lowercased() else {
            throw ToolError("outputPath must end in .\(format.fileExtension) for \(format.rawValue) export.")
        }
        let parent = outputURL.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("Output directory does not exist: \(parent.path)")
        }
        if fm.fileExists(atPath: outputURL.path), !overwrite {
            throw ToolError("Output already exists: \(outputURL.path). Pass overwrite=true to replace it.")
        }
    }

    private static func normalizedResolutionName(_ resolution: ExportResolution) -> String {
        switch resolution {
        case .r720p: "720p"
        case .r1080p: "1080p"
        case .r1440p: "1440p"
        case .r4k: "4k"
        case .native: "native"
        }
    }
}
