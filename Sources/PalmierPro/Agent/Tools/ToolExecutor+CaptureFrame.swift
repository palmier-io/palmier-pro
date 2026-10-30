import Foundation

private struct CaptureFrameInput: DecodableToolArgs {
    let timelineFrame: Int?
    let mediaRef: String?
    let sourceSeconds: Double?
    let name: String?

    static let allowedKeys: Set<String> = [
        "timelineFrame", "mediaRef", "sourceSeconds", "name",
    ]
}

extension ToolExecutor {
    private static let captureFrameNameLimit = 200

    func captureFrame(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: CaptureFrameInput = try decodeToolArgs(args, path: "capture_frame")

        let timelineFrame = input.timelineFrame
        let mediaRef = input.mediaRef
        let sourceSeconds = input.sourceSeconds
        let usesTimeline = timelineFrame != nil
        let usesMedia = mediaRef != nil || sourceSeconds != nil
        guard usesTimeline != usesMedia else {
            throw ToolError("Provide exactly one capture mode: timelineFrame, or mediaRef with sourceSeconds.")
        }

        let name = input.name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name {
            guard !name.isEmpty else { throw ToolError("name must not be empty.") }
            guard name.count <= Self.captureFrameNameLimit else {
                throw ToolError("name must be \(Self.captureFrameNameLimit) characters or fewer.")
            }
        }

        let source: FrameCaptureSource
        if let timelineFrame {
            source = .timeline(frame: timelineFrame)
        } else {
            guard let mediaRef, let sourceSeconds else {
                throw ToolError("mediaRef and sourceSeconds are both required for a source-video capture.")
            }
            source = .media(mediaRef: mediaRef, sourceSeconds: sourceSeconds)
        }

        let receipt = try await editor.captureFrameToMedia(source: source, name: name)
        var payload: [String: Any] = [
            "status": "ready",
            "mediaRef": receipt.asset.id,
            "name": receipt.asset.name,
            "type": receipt.asset.type.rawValue,
            "mimeType": "image/png",
            "width": receipt.width,
            "height": receipt.height,
        ]
        switch source {
        case .timeline(let frame):
            var capturedFrom: [String: Any] = ["timelineFrame": frame]
            if let timelineId = receipt.timelineId {
                capturedFrom["timelineId"] = timelineId
            }
            payload["capturedFrom"] = capturedFrom
        case .media(let mediaRef, let sourceSeconds):
            var capturedFrom: [String: Any] = [
                "mediaRef": mediaRef,
                "sourceSeconds": sourceSeconds,
            ]
            if let actual = receipt.actualSourceSeconds {
                capturedFrom["actualSourceSeconds"] = actual
            }
            payload["capturedFrom"] = capturedFrom
        }
        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 3)) else {
            throw ToolError("Failed to encode capture receipt.")
        }
        return .ok(json)
    }
}
