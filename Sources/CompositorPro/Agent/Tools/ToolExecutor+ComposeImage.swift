import Foundation

extension ToolExecutor {
    private struct ComposeImageInput: DecodableToolArgs {
        var mediaRefs: [String]?
        var query: String?
        var limit: Int?
        var layout: String?
        var preset: String?
        var headline: String?
        var subline: String?
        var textPlacement: String?
        var scrim: Bool?
        var name: String?
        var folderId: String?
        var addToTimeline: Bool?
        var startFrame: Int?

        static let allowedKeys: Set<String> = [
            "mediaRefs", "query", "limit", "layout", "preset", "headline", "subline",
            "textPlacement", "scrim", "name", "folderId", "addToTimeline", "startFrame",
        ]
    }

    /// Builds one image out of the project's own frames and stills.
    func composeImage(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ComposeImageInput.allowedKeys, path: "compose_image")
        let input: ComposeImageInput = try decodeToolArgs(args, path: "compose_image")

        let layout: ComposeLayout
        if let raw = input.layout, !raw.isEmpty {
            guard let parsed = ComposeLayout(rawValue: raw) else {
                let known = ComposeLayout.allCases.map(\.rawValue).joined(separator: ", ")
                throw ToolError("compose_image: layout must be one of: \(known). Got '\(raw)'.")
            }
            layout = parsed
        } else {
            layout = .grid
        }

        let preset: ThumbnailPreset
        if let raw = input.preset, !raw.isEmpty {
            guard let parsed = ThumbnailPreset(rawValue: raw) else {
                let known = ThumbnailPreset.allCases.map(\.rawValue).joined(separator: ", ")
                throw ToolError("compose_image: preset must be one of: \(known). Got '\(raw)'.")
            }
            preset = parsed
        } else {
            preset = .youtube
        }

        let placement: ThumbnailTextPlacement
        if let raw = input.textPlacement, !raw.isEmpty {
            guard let parsed = ThumbnailTextPlacement(rawValue: raw) else {
                let known = ThumbnailTextPlacement.allCases.map(\.rawValue).joined(separator: ", ")
                throw ToolError("compose_image: textPlacement must be one of: \(known). Got '\(raw)'.")
            }
            placement = parsed
        } else {
            placement = .bottomLeft
        }

        if let limit = input.limit, !(1 ... 12).contains(limit) {
            throw ToolError("compose_image: limit must be between 1 and 12; got \(limit).")
        }

        let query = input.query?.trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = input.mediaRefs ?? []
        if (query?.isEmpty ?? true) && refs.isEmpty {
            throw ToolError(
                "compose_image: pass query to find matching shots, or mediaRefs to choose them. "
                    + "With neither there is nothing to compose."
            )
        }

        let request = EditorViewModel.ComposeImageRequest(
            mediaRefs: refs,
            query: query,
            retrievalLimit: input.limit ?? 6,
            layout: layout,
            preset: preset,
            headline: input.headline ?? "",
            subline: input.subline ?? "",
            placement: placement,
            scrim: input.scrim ?? true,
            name: input.name,
            folderId: input.folderId,
            addToTimeline: input.addToTimeline ?? false,
            startFrame: input.startFrame ?? 0
        )

        let receipt: EditorViewModel.ComposeImageReceipt
        do {
            receipt = try await editor.composeImage(request)
        } catch let error as EditorViewModel.ComposeImageError {
            throw ToolError(error.description)
        }

        var payload: [String: Any] = [
            "mediaRef": receipt.asset.id,
            "name": receipt.asset.name,
            "path": receipt.asset.url.path,
            "width": receipt.width,
            "height": receipt.height,
            "layout": layout.rawValue,
            "preset": preset.rawValue,
            "sourceCount": receipt.sources.count,
            "sources": receipt.sources.map { source in
                var row: [String: Any] = ["mediaRef": source.mediaRef, "name": source.name]
                if let seconds = source.sourceSeconds { row["sourceSeconds"] = seconds }
                if let score = source.score { row["score"] = score }
                return row
            },
            "changed": true,
            "inLibrary": true,
            "undoSteps": 0,
        ]
        if let query { payload["query"] = query }
        if let clipId = receipt.clipId { payload["clipId"] = clipId }
        if !receipt.warnings.isEmpty { payload["warnings"] = receipt.warnings }

        var notes = [
            "The image was assembled from \(receipt.sources.count) of this project's own "
                + "frames and stills. Nothing was generated or downloaded.",
            "It is a library asset: add_clips places it on the timeline.",
        ]
        if receipt.clipId == nil {
            notes.append("Pass addToTimeline:true to place it in one step.")
        }
        if !receipt.warnings.isEmpty { notes.append(contentsOf: receipt.warnings) }
        payload["notes"] = notes

        return .ok(Self.jsonString(payload) ?? "{}")
    }
}
