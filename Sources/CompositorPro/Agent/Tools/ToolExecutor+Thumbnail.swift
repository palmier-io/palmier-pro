import Foundation

extension ToolExecutor {
    private struct GenerateThumbnailInput: DecodableToolArgs {
        let preset: String?
        let frame: Int?
        let title: String?
        let subtitle: String?
        let placement: String?
        let titleScale: Double?
        let scrim: Bool?
        let path: String?
        let fileName: String?
        static let allowedKeys: Set<String> = [
            "preset", "frame", "title", "subtitle", "placement",
            "titleScale", "scrim", "path", "fileName",
        ]
    }

    /// Writes a poster frame for the timeline as its own image file.
    func generateThumbnail(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: GenerateThumbnailInput = try decodeToolArgs(args, path: "generate_thumbnail")
        var spec = ThumbnailSpec()
        if let raw = input.preset {
            guard let preset = ThumbnailPreset(rawValue: raw) else {
                throw ToolError(ThumbnailError.unknownPreset(raw).description)
            }
            spec.preset = preset
        }
        if let placement = input.placement {
            guard let parsed = ThumbnailTextPlacement(rawValue: placement) else {
                throw ToolError("placement must be bottomLeft, bottomCenter, centerLeft or center.")
            }
            spec.placement = parsed
        }
        if let title = input.title { spec.title = title }
        if let subtitle = input.subtitle { spec.subtitle = subtitle }
        if let scale = input.titleScale {
            guard scale.isFinite, scale > 0.02, scale < 0.4 else {
                throw ToolError("titleScale must be a fraction of the frame's long edge, 0.02–0.4.")
            }
            spec.titleScale = scale
        }
        if let scrim = input.scrim { spec.scrim = scrim }

        // Checked on the raw string: URL(fileURLWithPath:) resolves a relative path against the
        // working directory, so testing the URL would always look absolute and pass.
        let directory = try input.path.map { raw -> URL in
            let expanded = (raw as NSString).expandingTildeInPath
            guard expanded.hasPrefix("/") else {
                throw ToolError("path must be absolute, e.g. ~/Desktop or /tmp/thumbs.")
            }
            return URL(fileURLWithPath: expanded)
        }
        // An omitted or blank name falls back to thumbnail.jpg; a blank one is not a mistake.
        let fileName = input.fileName.flatMap { $0.isEmpty ? nil : $0 }

        let receipt = try await editor.generateThumbnail(
            spec: spec, frame: input.frame, directory: directory, fileName: fileName
        )
        var notes = [
            "The thumbnail is a separate file. Nothing was added to the timeline.",
            "\(receipt.preset.rawValue) spec: \(receipt.preset.guidance)",
            "Actual size: \(receipt.width)x\(receipt.height), \(receipt.bytes / 1024) KB.",
        ]
        notes.append(
            receipt.frameWasChosen
                ? "Frame \(receipt.frame) was chosen by legibility scoring across \(receipt.framesConsidered) sampled frames — the most contrast with the least clipping, not a judgement about which shot is best. Pass frame to override."
                : "Used the frame you asked for."
        )
        if receipt.hasTitle {
            notes.append("The headline is drawn onto the image, not onto the video. Delete the title to get a clean poster.")
        }
        if receipt.preset != .timeline {
            notes.append("A non-timeline preset crops the project canvas to the target shape; the video itself is unchanged.")
        }
        return .ok(Self.jsonString([
            "path": receipt.url.path,
            "preset": receipt.preset.rawValue,
            "frame": receipt.frame,
            "width": receipt.width,
            "height": receipt.height,
            "bytes": receipt.bytes,
            "frameWasChosen": receipt.frameWasChosen,
            "framesConsidered": receipt.framesConsidered,
            "hasTitle": receipt.hasTitle,
            "changed": true,
            "notes": notes,
        ]) ?? "{}")
    }
}