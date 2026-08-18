import CoreGraphics

enum PreviewCanvasAspect {
    static func ratio(width: Int, height: Int) -> CGFloat {
        CGFloat(max(1, width)) / CGFloat(max(1, height))
    }

    static func sourcePreviewRatio(
        sourceWidth: Int?,
        sourceHeight: Int?,
        generationAspectRatio: String?,
        timelineWidth: Int,
        timelineHeight: Int
    ) -> CGFloat {
        if let sourceWidth, let sourceHeight, sourceWidth > 0, sourceHeight > 0 {
            return ratio(width: sourceWidth, height: sourceHeight)
        }
        if let generationAspectRatio, let parsed = try? CanvasAspectRatio(generationAspectRatio) {
            return CGFloat(parsed.horizontal / parsed.vertical)
        }
        return ratio(width: timelineWidth, height: timelineHeight)
    }
}
