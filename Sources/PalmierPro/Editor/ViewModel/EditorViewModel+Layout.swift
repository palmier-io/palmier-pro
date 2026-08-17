import Foundation

extension EditorViewModel {

    func layoutPlacement(
        for clip: Clip,
        in rect: LayoutRect,
        fit: LayoutFit,
        anchorX: Double = 0.5,
        anchorY: Double = 0.5
    ) -> (transform: Transform, crop: Crop) {
        let canvasAspect = Double(timeline.width) / Double(max(1, timeline.height))
        let slotPixelAspect = rect.h > 0 ? (rect.w / rect.h) * canvasAspect : canvasAspect
        let contentCrop = clip.crop
        guard let dimensions = sourceDimensions(for: clip),
              contentCrop.visibleWidthFraction > 0,
              contentCrop.visibleHeightFraction > 0 else {
            return (Transform(topLeft: (rect.x, rect.y), width: rect.w, height: rect.h), Crop())
        }
        let contentPixelAspect = Double(dimensions.width) / Double(dimensions.height)
            * contentCrop.visibleWidthFraction / contentCrop.visibleHeightFraction

        switch fit {
        case .fill:
            let crop = Self.cropFittingAspect(
                sourcePixelAspect: contentPixelAspect,
                targetPixelAspect: slotPixelAspect,
                anchorX: anchorX,
                anchorY: anchorY
            )
            let effectiveCrop = contentCrop.composed(with: crop)
            let vw = effectiveCrop.visibleWidthFraction
            let vh = effectiveCrop.visibleHeightFraction
            guard vw > 0, vh > 0 else {
                return (Transform(topLeft: (rect.x, rect.y), width: rect.w, height: rect.h), crop)
            }
            let w = rect.w / vw
            let h = rect.h / vh
            let x = rect.x - effectiveCrop.left * w
            let y = rect.y - effectiveCrop.top * h
            return (Transform(topLeft: (x, y), width: w, height: h), crop)

        case .fit:
            let rel = contentPixelAspect / canvasAspect
            guard rel > 0 else {
                return (Transform(topLeft: (rect.x, rect.y), width: rect.w, height: rect.h), Crop())
            }
            var drawW = rect.w
            var drawH = rect.h
            if rel * rect.h <= rect.w {
                drawH = rect.h
                drawW = rel * rect.h
            } else {
                drawW = rect.w
                drawH = rect.w / rel
            }
            let ax = min(1, max(0, anchorX))
            let ay = min(1, max(0, anchorY))
            let visibleX = rect.x + (rect.w - drawW) * ax
            let visibleY = rect.y + (rect.h - drawH) * ay
            let width = drawW / contentCrop.visibleWidthFraction
            let height = drawH / contentCrop.visibleHeightFraction
            let x = visibleX - contentCrop.left * width
            let y = visibleY - contentCrop.top * height
            return (Transform(topLeft: (x, y), width: width, height: height), Crop())
        }
    }

    private static func cropFittingAspect(
        sourcePixelAspect: Double,
        targetPixelAspect: Double,
        anchorX: Double,
        anchorY: Double
    ) -> Crop {
        guard sourcePixelAspect.isFinite, sourcePixelAspect > 0,
              targetPixelAspect.isFinite, targetPixelAspect > 0 else {
            return Crop()
        }
        if abs(sourcePixelAspect - targetPixelAspect) < 0.0001 { return Crop() }
        let x = min(1, max(0, anchorX))
        let y = min(1, max(0, anchorY))
        if sourcePixelAspect > targetPixelAspect {
            let total = 1 - targetPixelAspect / sourcePixelAspect
            let left = total * x
            return Crop(left: left, right: total - left)
        }
        let total = 1 - sourcePixelAspect / targetPixelAspect
        let top = total * y
        return Crop(top: top, bottom: total - top)
    }
}
