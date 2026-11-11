import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Headless CLI entry point for Compositor Pro operations.
final class CLIHandler: Sendable {

    /// Known CLI subcommands.
    static let subcommands: Set<String> = [
        "init", "preview", "render", "hyperframes", "help", "--help", "-h", "version", "--version"
    ]

    /// Determines whether command line arguments represent a headless CLI run.
    static func isCLIInvocation(_ arguments: [String]) -> Bool {
        guard arguments.count > 1 else { return false }
        let arg1 = arguments[1]
        if arg1.starts(with: "-NS") || arg1.starts(with: "-Apple") || arg1.starts(with: "-psn_") {
            return false
        }
        return subcommands.contains(arg1.lowercased())
    }

    /// Runs the CLI with given arguments and prints to standard output / error.
    static func run(
        _ arguments: [String],
        printOut: @escaping @Sendable (String) -> Void = { Swift.print($0) },
        printErr: @escaping @Sendable (String) -> Void = { fputs("\($0)\n", stderr) }
    ) async -> Int {
        guard arguments.count > 1 else {
            printOut(helpText())
            return 0
        }

        let subcommand = arguments[1].lowercased()
        let rest = Array(arguments.dropFirst(2))

        do {
            switch subcommand {
            case "help", "--help", "-h":
                printOut(helpText())
                return 0

            case "version", "--version":
                printOut("CompositorPro 1.0.0 (HyperFrames enabled, macOS 26, arm64)")
                return 0

            case "init":
                let message = try await handleInit(rest)
                printOut(message)
                return 0

            case "preview":
                let message = try await handlePreview(rest)
                printOut(message)
                return 0

            case "render":
                let message = try await handleRender(rest)
                printOut(message)
                return 0

            case "hyperframes":
                let message = try await handleHyperframes(rest)
                printOut(message)
                return 0

            default:
                printErr("Unknown subcommand '\(subcommand)'. Use 'compositor-pro help' for usage.")
                return 1
            }
        } catch {
            printErr("Error: \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: - Init Command

    /// Creates a new CompositorPro project package with initial configuration.
    static func handleInit(_ args: [String]) async throws -> String {
        var projectName = "Untitled"
        var destinationDir: String?
        var fps = 30
        var width = 1920
        var height = 1080
        var withTemplate = false

        var i = 0
        while i < args.count {
            let arg = args[i]
            if !arg.starts(with: "--") && !arg.starts(with: "-") && projectName == "Untitled" && i == 0 {
                projectName = arg
            } else if arg == "--path" || arg == "-p", i + 1 < args.count {
                destinationDir = args[i + 1]
                i += 1
            } else if arg == "--fps", i + 1 < args.count {
                fps = Int(args[i + 1]) ?? fps
                i += 1
            } else if arg == "--width", i + 1 < args.count {
                width = Int(args[i + 1]) ?? width
                i += 1
            } else if arg == "--height", i + 1 < args.count {
                height = Int(args[i + 1]) ?? height
                i += 1
            } else if arg == "--template" || arg == "-t" {
                withTemplate = true
            }
            i += 1
        }

        let basePath: URL
        if let dir = destinationDir {
            basePath = URL(fileURLWithPath: dir)
        } else {
            basePath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        }

        let packageURL = basePath.appendingPathComponent("\(projectName).compositorpro", isDirectory: true)

        let finalPackageURL = packageURL
        let finalProjectName = projectName
        let finalFps = fps
        let finalWidth = width
        let finalHeight = height
        let finalWithTemplate = withTemplate

        try await Task.detached {
            let fm = FileManager.default
            try fm.createDirectory(at: finalPackageURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: finalPackageURL.appendingPathComponent("Media"), withIntermediateDirectories: true)

            let timeline = Timeline(
                id: UUID().uuidString,
                name: finalProjectName,
                fps: finalFps,
                width: finalWidth,
                height: finalHeight,
                tracks: [
                    Track(id: UUID().uuidString, type: .video, name: "Video 1", clips: []),
                    Track(id: UUID().uuidString, type: .audio, name: "Audio 1", clips: [])
                ]
            )

            let projectFile = ProjectFile(
                timelines: [timeline],
                activeTimelineId: timeline.id,
                openTimelineIds: [timeline.id]
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let projectData = try encoder.encode(projectFile)
            let projectJsonURL = finalPackageURL.appendingPathComponent("project.json")
            try projectData.write(to: projectJsonURL, options: .atomic)

            if finalWithTemplate {
                let storyboardContent = """
                # \(finalProjectName) Storyboard

                ## Beat 1: Intro Hook [00:00:00 - 00:00:04]
                - Visual: Bold headline animation with brand gradient
                - Narration: Welcome to next-generation video creation.
                - Motion: kinetic-title-reveal

                ## Beat 2: Showcase [00:00:04 - 00:00:10]
                - Visual: Dual-screen feature walkthrough
                - Narration: High precision, hardware accelerated.
                """
                let storyboardURL = finalPackageURL.appendingPathComponent("STORYBOARD.md")
                try storyboardContent.write(to: storyboardURL, atomically: true, encoding: .utf8)
            }
        }.value

        return "Successfully created project '\(finalProjectName)' at \(finalPackageURL.path)"
    }

    // MARK: - Preview Command

    /// Captures and optionally saves a preview frame from the project timeline.
    static func handlePreview(_ args: [String]) async throws -> String {
        guard let projectPath = args.first(where: { !$0.starts(with: "-") }) else {
            throw CLIError.missingArgument("Project path is required. Usage: compositor-pro preview <path> [--frame <n>] [--output <out.png>]")
        }

        var targetFrame = 0
        var outputPath: String?

        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--frame" || arg == "-f", i + 1 < args.count {
                targetFrame = Int(args[i + 1]) ?? targetFrame
                i += 1
            } else if arg == "--output" || arg == "-o", i + 1 < args.count {
                outputPath = args[i + 1]
                i += 1
            }
            i += 1
        }

        let projectURL = URL(fileURLWithPath: projectPath)
        let (timeline, _) = try await loadProjectTimeline(from: projectURL)

        let resolver = MediaResolver(manifest: { MediaManifest() }, projectURL: { projectURL })
        let frame = try await FrameCaptureRenderer.timeline(
            timeline,
            frame: targetFrame,
            mediaURLs: resolver.expectedURLMap(),
            resolveTimeline: { _ in nil },
            missingMediaRefs: []
        )

        if let outPath = outputPath {
            let destURL = URL(fileURLWithPath: outPath)
            if let thumbnail = frame.thumbnail {
                try saveCGImageAsPNG(thumbnail, to: destURL)
            } else if FileManager.default.fileExists(atPath: frame.stagedURL.path) {
                try? FileManager.default.removeItem(at: destURL)
                try FileManager.default.copyItem(at: frame.stagedURL, to: destURL)
            } else {
                throw CLIError.renderFailed("Could not acquire preview frame data")
            }
            return "Rendered preview frame \(targetFrame) (\(frame.width)x\(frame.height)) -> \(destURL.path)"
        }

        return "Rendered preview frame \(targetFrame) (\(frame.width)x\(frame.height)) successfully"
    }

    // MARK: - Render Command

    /// Headlessly exports the project timeline.
    static func handleRender(_ args: [String]) async throws -> String {
        guard let projectPath = args.first(where: { !$0.starts(with: "-") }) else {
            throw CLIError.missingArgument("Project path is required. Usage: compositor-pro render <path> [--output <out.mp4>] [--format h264|prores]")
        }

        var outputPath: String?
        var format: ExportFormat = .h264
        var resolution: ExportResolution = .matchTimeline

        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--output" || arg == "-o", i + 1 < args.count {
                outputPath = args[i + 1]
                i += 1
            } else if arg == "--format", i + 1 < args.count {
                let fmtStr = args[i + 1].lowercased()
                switch fmtStr {
                case "prores": format = .prores
                case "h265": format = .h265
                case "hdr", "hevchdr": format = .hevcHDR
                case "xml": format = .xml
                case "fcpxml": format = .fcpxml
                default: format = .h264
                }
                i += 1
            } else if arg == "--resolution", i + 1 < args.count {
                let resStr = args[i + 1].lowercased()
                switch resStr {
                case "720p": resolution = .r720p
                case "1080p": resolution = .r1080p
                case "2k", "1440p": resolution = .r1440p
                case "4k", "2160p": resolution = .r4k
                default: resolution = .matchTimeline
                }
                i += 1
            }
            i += 1
        }

        let projectURL = URL(fileURLWithPath: projectPath)
        let (timeline, _) = try await loadProjectTimeline(from: projectURL)

        let targetOutputURL: URL
        if let out = outputPath {
            targetOutputURL = URL(fileURLWithPath: out)
        } else {
            let outDir = projectURL.deletingLastPathComponent()
            let baseName = projectURL.deletingPathExtension().lastPathComponent
            targetOutputURL = outDir.appendingPathComponent("\(baseName).\(format.fileExtension)")
        }

        let resolver = MediaResolver(manifest: { MediaManifest() }, projectURL: { projectURL })

        let exportService = await MainActor.run {
            ExportService()
        }

        await exportService.export(
            timeline: timeline,
            resolver: resolver,
            format: format,
            resolution: resolution,
            outputURL: targetOutputURL
        )

        let error = await exportService.error
        if let error = error {
            throw CLIError.renderFailed("Export failed: \(error)")
        }

        return "Successfully rendered project to \(targetOutputURL.path)"
    }

    // MARK: - Hyperframes Command

    /// CLI interactions with the HyperFrames catalog and templates.
    static func handleHyperframes(_ args: [String]) async throws -> String {
        guard !args.isEmpty else {
            return "Usage: compositor-pro hyperframes [catalog | inspect <blockId> | html <blockId> [--output <file>]]"
        }

        let action = args[0].lowercased()
        switch action {
        case "catalog", "list":
            let catalog = HyperframesCatalogWrapper.loadCatalog()
            var lines = ["HyperFrames Catalog (\(catalog.count) blocks):"]
            for block in catalog {
                let durationSec = Double(block.defaultDurationFrames ?? 90) / 30.0
                lines.append("  - [\(block.category)] \(block.id): \(block.name) (\(String(format: "%.1f", durationSec))s)")
            }
            return lines.joined(separator: "\n")

        case "inspect":
            guard args.count > 1 else { throw CLIError.missingArgument("Block ID required: compositor-pro hyperframes inspect <blockId>") }
            let blockId = args[1]
            guard let spec = HyperframesCatalogWrapper.inspectBlock(id: blockId) else {
                throw CLIError.notFound("HyperFrames block '\(blockId)' not found in catalog")
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(spec)
            return String(decoding: data, as: UTF8.self)

        case "html":
            guard args.count > 1 else { throw CLIError.missingArgument("Block ID required: compositor-pro hyperframes html <blockId>") }
            let blockId = args[1]
            guard let spec = HyperframesCatalogWrapper.inspectBlock(id: blockId) else {
                throw CLIError.notFound("HyperFrames block '\(blockId)' not found in catalog")
            }
            var title: String?
            var outputPath: String?
            var i = 2
            while i < args.count {
                if args[i] == "--title", i + 1 < args.count {
                    title = args[i + 1]
                    i += 1
                } else if args[i] == "--output" || args[i] == "-o", i + 1 < args.count {
                    outputPath = args[i + 1]
                    i += 1
                }
                i += 1
            }
            var params: [String: String] = [:]
            if let t = title { params["title"] = t }
            let html = HyperframesCatalogWrapper.generateTemplateHTML(for: spec, parameters: params)
            if let outPath = outputPath {
                let outURL = URL(fileURLWithPath: outPath)
                try html.write(to: outURL, atomically: true, encoding: .utf8)
                return "Exported HTML template for '\(blockId)' -> \(outURL.path)"
            }
            return html

        default:
            throw CLIError.unknownCommand("Unknown hyperframes action '\(action)'")
        }
    }

    // MARK: - Helper Methods

    /// Loads the active timeline from a project directory or package.
    static func loadProjectTimeline(from url: URL) async throws -> (Timeline, ProjectFile) {
        try await Task.detached { [url] in
            let jsonURL: URL
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                jsonURL = url.appendingPathComponent("project.json")
            } else {
                jsonURL = url
            }

            guard FileManager.default.fileExists(atPath: jsonURL.path) else {
                throw CLIError.notFound("Project file not found at \(jsonURL.path)")
            }

            let data = try Data(contentsOf: jsonURL)
            let project = try ProjectFile.decode(data)
            guard let timeline = project.timelines.first else {
                throw CLIError.invalidProject("Project contains no timelines")
            }
            return (timeline, project)
        }.value
    }

    /// Saves a CGImage as a PNG file.
    private static func saveCGImageAsPNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CLIError.renderFailed("Could not create image destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CLIError.renderFailed("Could not finalize PNG image")
        }
    }

    /// CLI usage string.
    static func helpText() -> String {
        """
        CompositorPro CLI — High-performance video creation & HyperFrames motion tool

        USAGE:
          compositor-pro <subcommand> [options]

        SUBCOMMANDS:
          init <name> [--path <dir>] [--fps <fps>] [--width <width>] [--height <height>] [--template]
            Scaffold a new CompositorPro project package.

          preview <project-path> [--frame <n>] [--output <out.png>]
            Render and export a frame from the project timeline.

          render <project-path> [--output <out.mp4>] [--format h264|prores|h265|hdr] [--resolution 1080p|4k|720p]
            Headlessly render and export the project timeline.

          hyperframes <action> [options]
            Inspect and export HyperFrames motion catalog blocks.
            Actions:
              catalog               List catalog blocks
              inspect <blockId>     Print block specification JSON
              html <blockId> [-o <out.html>] [--title <title>] Export self-contained HTML

          help
            Show this help reference.
        """
    }
}

/// Errors thrown during CLI execution.
enum CLIError: LocalizedError {
    case missingArgument(String)
    case notFound(String)
    case invalidProject(String)
    case renderFailed(String)
    case unknownCommand(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let msg): return msg
        case .notFound(let msg): return msg
        case .invalidProject(let msg): return msg
        case .renderFailed(let msg): return msg
        case .unknownCommand(let msg): return msg
        }
    }
}
