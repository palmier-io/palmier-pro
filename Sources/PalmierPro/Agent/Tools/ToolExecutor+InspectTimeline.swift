import Foundation

extension ToolExecutor {
    private static let inspectTimelineAllowedKeys: Set<String> = ["startFrame", "endFrame", "maxFrames"]

    func inspectTimeline(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.inspectTimelineAllowedKeys, path: "inspect_timeline")
        let frames = try await TimelineFrameSampler.sample(
            timeline: editor.timeline,
            editor: editor,
            startFrame: args.int("startFrame") ?? 0,
            endFrame: args.int("endFrame"),
            maxFrames: args.int("maxFrames") ?? TimelineFrameSampler.defaultFrameCount,
            burnLabels: true
        )
        let imageBlocks = frames.map {
            ToolResult.Block.image(base64: $0.jpeg.base64EncodedString(), mediaType: "image/jpeg")
        }
        let meta: [String: Any] = [
            "fps": editor.timeline.fps,
            "width": frames[0].width,
            "height": frames[0].height,
            "totalFrames": editor.timeline.totalFrames,
            "frames": frames.map { frame -> [String: Any] in
                ["frame": frame.frame, "clips": frame.clipIds]
            },
        ]
        guard let metaJSON = Self.jsonString(meta) else { throw ToolError("Failed to encode metadata") }
        return ToolResult(content: imageBlocks + [.text(metaJSON)], isError: false)
    }

    static func visibleClips(at frame: Int, in timeline: Timeline) -> [String] {
        TimelineFrameSampler.visibleClips(at: frame, in: timeline)
    }
}
