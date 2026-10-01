import Foundation

extension ToolExecutor {
    private struct SetClipSpeedRampInput: DecodableToolArgs {
        struct Point: Decodable {
            let frame: Int?
            let speed: Double?
        }
        let clipId: String?
        let points: [Point]?
        let clear: Bool?
        static let allowedKeys: Set<String> = ["clipId", "points", "clear"]
    }

    /// Sets or clears a variable speed envelope on a clip, as one undo step.
    func setClipSpeedRamp(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let input: SetClipSpeedRampInput = try decodeToolArgs(args, path: "set_clip_speed_ramp")
        guard let clipId = input.clipId, !clipId.isEmpty else {
            throw ToolError("set_clip_speed_ramp requires clipId.")
        }
        do {
            if input.clear == true {
                let receipt = try editor.clearSpeedRamp(clipId: clipId)
                return .ok(Self.jsonString([
                    "clipId": receipt.clipId,
                    "cleared": true,
                    "speed": receipt.points.first?.speed ?? 1,
                    "durationFrames": editor.clipFor(id: clipId)?.durationFrames ?? 0,
                    "changed": true,
                ]) ?? "{}")
            }
            guard let rawPoints = input.points, !rawPoints.isEmpty else {
                throw ToolError("set_clip_speed_ramp needs points, or clear:true.")
            }
            var points: [EditorViewModel.SpeedRampPoint] = []
            for raw in rawPoints {
                guard let frame = raw.frame else { throw ToolError("Each ramp point needs a frame.") }
                guard let speed = raw.speed else { throw ToolError("Each ramp point needs a speed.") }
                points.append(.init(frame: frame, speed: speed))
            }
            let receipt = try editor.applySpeedRamp(clipId: clipId, points: points)
            return .ok(Self.jsonString([
                "clipId": receipt.clipId,
                "points": receipt.points.map { ["frame": $0.frame, "speed": $0.speed] },
                "sourceFramesConsumed": receipt.sourceFramesConsumed,
                "previousSpeed": receipt.previousSpeed,
                "changed": true,
                "notes": [
                    "The clip keeps its timeline length; the ramp decides how much source it reads "
                        + "(\(receipt.sourceFramesConsumed) frames now).",
                    "set_clip_properties speed still sets one constant rate and clears the ramp.",
                ],
            ]) ?? "{}")
        } catch let error as SpeedRampError {
            throw ToolError(error.description)
        }
    }
}
