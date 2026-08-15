import AVFoundation
import CoreImage
import CoreText
import Foundation

private struct CropToSubjectInput: DecodableToolArgs {
    struct Bounds: DecodableToolArgs {
        let left: Double
        let top: Double
        let right: Double
        let bottom: Double

        static let allowedKeys: Set<String> = ["left", "top", "right", "bottom"]
    }

    let clipId: String
    let prompt: String
    let atFrame: Int?
    let bounds: Bounds?
    let apply: Bool?

    static let allowedKeys: Set<String> = ["clipId", "prompt", "atFrame", "bounds", "apply"]
}

extension ToolExecutor {
    private static let cropPromptLimit = 500
    private static let cropPreviewJPEGQuality: CGFloat = 0.82

    func cropToSubject(
        _ editor: EditorViewModel,
        _ args: [String: Any]
    ) async throws -> ToolResult {
        if let rawBounds = args["bounds"] {
            guard let bounds = rawBounds as? [String: Any] else {
                throw ToolError("crop_to_subject.bounds: expected object")
            }
            try validateUnknownKeys(
                bounds,
                allowed: CropToSubjectInput.Bounds.allowedKeys,
                path: "crop_to_subject.bounds"
            )
        }
        let input: CropToSubjectInput = try decodeToolArgs(args, path: "crop_to_subject")
        let prompt = input.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { throw ToolError("prompt must not be empty.") }
        guard prompt.count <= Self.cropPromptLimit else {
            throw ToolError("prompt must be \(Self.cropPromptLimit) characters or fewer.")
        }
        guard input.bounds != nil || input.apply != true else {
            throw ToolError("bounds are required when apply is true.")
        }

        guard let originalClip = editor.clipFor(id: input.clipId) else {
            throw ToolError("Clip not found: \(input.clipId)")
        }
        guard originalClip.mediaType == .video || originalClip.mediaType == .image else {
            throw ToolError(
                "Clip \(input.clipId) is a \(originalClip.mediaType.rawValue) clip; "
                    + "crop_to_subject requires video or image."
            )
        }
        guard originalClip.durationFrames > 0 else {
            throw ToolError("Clip \(input.clipId) has no visible frames.")
        }

        let atFrame = try Self.cropInspectionFrame(input.atFrame, clip: originalClip)
        let crop = try input.bounds.map(Self.crop(from:))
        let originalTimelineId = editor.activeTimelineId
        let media = try asset(originalClip.mediaRef, editor: editor, label: "Clip source")
        guard let url = editor.mediaResolver.resolveURL(for: originalClip.mediaRef) else {
            throw ToolError("Could not resolve a source URL for clip \(input.clipId).")
        }

        let sourceSeconds = (
            Double(originalClip.trimStartFrame)
                + Double(atFrame - originalClip.startFrame) * originalClip.speed
        ) / Double(max(1, editor.timeline.fps))
        let sourceFrame = try await PromptCropRenderer.sourceFrame(
            url: url,
            type: media.type,
            sourceSeconds: sourceSeconds
        )
        try Task.checkCancellation()

        guard editor.activeTimelineId == originalTimelineId,
              editor.clipFor(id: input.clipId) == originalClip else {
            throw ToolError("Clip \(input.clipId) changed while the crop preview was rendering. Retry.")
        }

        guard let gridded = PromptCropRenderer.drawGrid(on: sourceFrame, selection: input.bounds),
              let griddedJPEG = ImageEncoder.encodeJPEG(
                gridded,
                quality: Self.cropPreviewJPEGQuality
              ) else {
            throw ToolError("Failed to render the crop guide.")
        }

        var blocks: [ToolResult.Block] = [
            .image(base64: griddedJPEG.base64EncodedString(), mediaType: "image/jpeg"),
        ]
        if let crop,
           let preview = PromptCropRenderer.crop(sourceFrame, to: crop),
           let previewJPEG = ImageEncoder.encodeJPEG(
               preview,
               quality: Self.cropPreviewJPEGQuality
           ) {
            blocks.append(.image(base64: previewJPEG.base64EncodedString(), mediaType: "image/jpeg"))
        } else if crop != nil {
            throw ToolError("Failed to render the proposed crop.")
        }

        let status: String
        var changed = false
        if let crop, input.apply == true {
            editor.undo.perform("Crop to Subject (Agent)") {
                editor.commitClipProperty(
                    clipId: input.clipId,
                    actionName: "Crop to Subject (Agent)"
                ) {
                    $0.crop = crop
                    $0.cropTrack = nil
                }
            }
            changed = editor.clipFor(id: input.clipId) != originalClip
            status = changed ? "applied" : "unchanged"
        } else {
            status = crop == nil ? "needsBounds" : "preview"
        }

        var payload: [String: Any] = [
            "status": status,
            "clipId": input.clipId,
            "prompt": prompt,
            "atFrame": atFrame,
            "sourceWidth": sourceFrame.width,
            "sourceHeight": sourceFrame.height,
            "grid": [
                "columns": "A-J",
                "rows": "1-10",
                "origin": "top-left",
                "coordinates": "normalized 0-1 source coordinates",
            ],
            "currentBounds": Self.boundsJSON(originalClip.cropAt(frame: atFrame)),
        ]
        if let crop {
            payload["proposedBounds"] = Self.boundsJSON(crop)
            payload["crop"] = Self.cropJSON(crop)
            payload["changed"] = changed
        } else {
            payload["next"] = "Return approximate bounds for the prompted subject, then call again with bounds to preview."
        }
        if crop != nil, input.apply != true {
            payload["next"] = "Inspect both images. Refine bounds with another preview call, or set apply=true to commit one undoable crop."
        }
        if input.apply == true {
            payload["clearedCropKeyframes"] = originalClip.cropTrack?.isActive == true
        }

        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(payload, toPlaces: 4)) else {
            throw ToolError("Failed to encode crop receipt.")
        }
        blocks.append(.text(json))
        return ToolResult(content: blocks, isError: false)
    }

    private static func cropInspectionFrame(_ requested: Int?, clip: Clip) throws -> Int {
        if let requested {
            guard clip.contains(timelineFrame: requested) else {
                throw ToolError(
                    "atFrame \(requested) is outside clip \(clip.id) range "
                        + "[\(clip.startFrame), \(clip.endFrame))."
                )
            }
            return requested
        }
        let midpoint = clip.durationFrames / 2
        let (frame, overflow) = clip.startFrame.addingReportingOverflow(midpoint)
        guard !overflow, clip.contains(timelineFrame: frame) else {
            throw ToolError("Could not choose a representative frame for clip \(clip.id).")
        }
        return frame
    }

    private static func crop(from bounds: CropToSubjectInput.Bounds) throws -> Crop {
        let values = [bounds.left, bounds.top, bounds.right, bounds.bottom]
        guard values.allSatisfy(\.isFinite) else {
            throw ToolError("bounds values must be finite.")
        }
        guard values.allSatisfy({ (0...1).contains($0) }) else {
            throw ToolError("bounds values must be within 0...1.")
        }
        guard bounds.right > bounds.left, bounds.bottom > bounds.top else {
            throw ToolError("bounds must satisfy left < right and top < bottom.")
        }
        guard bounds.right - bounds.left >= Crop.minimumVisibleFraction,
              bounds.bottom - bounds.top >= Crop.minimumVisibleFraction else {
            throw ToolError(
                "bounds must keep at least \(Crop.minimumVisibleFraction) "
                    + "of the source visible on each axis."
            )
        }
        return Crop(
            left: bounds.left,
            top: bounds.top,
            right: 1 - bounds.right,
            bottom: 1 - bounds.bottom
        )
    }

    private static func boundsJSON(_ crop: Crop) -> [String: Double] {
        [
            "left": crop.left,
            "top": crop.top,
            "right": 1 - crop.right,
            "bottom": 1 - crop.bottom,
        ]
    }

    private static func cropJSON(_ crop: Crop) -> [String: Double] {
        [
            "left": crop.left,
            "top": crop.top,
            "right": crop.right,
            "bottom": crop.bottom,
        ]
    }
}

private enum PromptCropRenderer {
    private static let maximumDimension = 1_024
    private static let gridDivisions = 10

    @concurrent
    static func sourceFrame(
        url: URL,
        type: ClipType,
        sourceSeconds: Double
    ) async throws -> CGImage {
        if type == .image {
            guard let image = ImageEncoder.thumbnail(
                url: url,
                maxPixelSize: maximumDimension
            ) else {
                throw ToolError("Could not decode the source image.")
            }
            return image
        }
        do {
            return try await FrameCaptureRenderer.sourcePreview(
                url: url,
                sourceSeconds: sourceSeconds,
                maximumDimension: CGFloat(maximumDimension)
            ).image
        } catch {
            throw ToolError("Could not decode the source video frame: \(error.localizedDescription)")
        }
    }

    nonisolated static func drawGrid(
        on image: CGImage,
        selection: CropToSubjectInput.Bounds?
    ) -> CGImage? {
        guard let context = context(width: image.width, height: image.height) else { return nil }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let lineWidth = max(1, min(width, height) / 700)
        context.setLineWidth(lineWidth)
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.72))
        for index in 1..<gridDivisions {
            let x = width * CGFloat(index) / CGFloat(gridDivisions)
            let y = height * CGFloat(index) / CGFloat(gridDivisions)
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: height))
            context.move(to: CGPoint(x: 0, y: y))
            context.addLine(to: CGPoint(x: width, y: y))
        }
        context.strokePath()

        let cellWidth = width / CGFloat(gridDivisions)
        let cellHeight = height / CGFloat(gridDivisions)
        let fontSize = max(5, min(18, min(cellWidth, cellHeight) * 0.22))
        for row in 0..<gridDivisions {
            for column in 0..<gridDivisions {
                let columnName = String(UnicodeScalar(65 + column)!)
                let label = "\(columnName)\(row + 1)"
                let center = CGPoint(
                    x: (CGFloat(column) + 0.5) * cellWidth,
                    y: height - (CGFloat(row) + 0.5) * cellHeight
                )
                drawLabel(label, centeredAt: center, fontSize: fontSize, context: context)
            }
        }

        if let selection {
            let rect = CGRect(
                x: CGFloat(selection.left) * width,
                y: (1 - CGFloat(selection.bottom)) * height,
                width: CGFloat(selection.right - selection.left) * width,
                height: CGFloat(selection.bottom - selection.top) * height
            )
            context.setStrokeColor(CGColor(red: 1, green: 0.78, blue: 0, alpha: 1))
            context.setLineWidth(max(3, lineWidth * 3))
            context.stroke(rect.insetBy(dx: 1, dy: 1))
        }
        return context.makeImage()
    }

    nonisolated static func crop(_ image: CGImage, to crop: Crop) -> CGImage? {
        let input = CIImage(cgImage: image)
        let extent = input.extent
        let cropRect = CGRect(
            x: extent.minX + CGFloat(crop.left) * extent.width,
            y: extent.minY + CGFloat(crop.bottom) * extent.height,
            width: CGFloat(crop.visibleWidthFraction) * extent.width,
            height: CGFloat(crop.visibleHeightFraction) * extent.height
        ).integral
        guard cropRect.width >= 1, cropRect.height >= 1 else { return nil }
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(
            input.cropped(to: cropRect),
            from: cropRect
        )
    }

    private nonisolated static func context(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private nonisolated static func drawLabel(
        _ text: String,
        centeredAt center: CGPoint,
        fontSize: CGFloat,
        context: CGContext
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            kCTFontAttributeName as NSAttributedString.Key:
                CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil),
            kCTForegroundColorAttributeName as NSAttributedString.Key:
                CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        let textWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let padding = max(2, fontSize * 0.18)
        let labelRect = CGRect(
            x: center.x - textWidth / 2 - padding,
            y: center.y - fontSize / 2 - padding,
            width: textWidth + padding * 2,
            height: fontSize + padding * 2
        )
        context.setFillColor(CGColor(gray: 0, alpha: 0.58))
        context.fill(labelRect)
        context.textPosition = CGPoint(
            x: center.x - textWidth / 2,
            y: center.y - fontSize * 0.36
        )
        CTLineDraw(line, context)
    }
}
