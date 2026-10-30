import CoreGraphics

struct TextTiltCorners {
    let topLeft: CGPoint
    let topRight: CGPoint
    let bottomRight: CGPoint
    let bottomLeft: CGPoint

    var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }

    func contains(_ point: CGPoint) -> Bool {
        let quad = points
        var hasPositive = false
        var hasNegative = false
        for (index, start) in quad.enumerated() {
            let end = quad[(index + 1) % quad.count]
            let cross = (end.x - start.x) * (point.y - start.y)
                - (end.y - start.y) * (point.x - start.x)
            hasPositive = hasPositive || cross > 0
            hasNegative = hasNegative || cross < 0
        }
        return !(hasPositive && hasNegative)
    }
}

/// Projective X/Y tilt plus Z rotation, in top-left canvas coordinates.
enum TextTiltGeometry {
    static func corners(
        of rect: CGRect,
        around pivot: CGPoint,
        transform: Transform,
        canvasSize: CGSize
    ) -> TextTiltCorners {
        let (sinX, cosX) = sinCos(transform.rotationX)
        let (sinY, cosY) = sinCos(transform.rotationY)
        let (sinZ, cosZ) = sinCos(transform.rotation)

        let canvasExtent = max(canvasSize.width, canvasSize.height)
        guard canvasExtent.isFinite, canvasExtent > 0 else {
            return TextTiltCorners(
                topLeft: CGPoint(x: rect.minX, y: rect.minY),
                topRight: CGPoint(x: rect.maxX, y: rect.minY),
                bottomRight: CGPoint(x: rect.maxX, y: rect.maxY),
                bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
            )
        }
        // Focal length is rect-independent so every surface shares one projection.
        let maxHalfWidth = max(
            abs(transform.width) * canvasSize.width / 2,
            abs(pivot.x),
            abs(canvasSize.width - pivot.x)
        )
        let maxHalfHeight = max(
            abs(transform.height) * canvasSize.height / 2,
            abs(pivot.y),
            abs(canvasSize.height - pivot.y)
        )
        let maxDepth = maxHalfWidth * abs(sinY) + maxHalfHeight * abs(sinX * cosY)
        let focalLength = max(canvasExtent * 2, maxDepth + canvasExtent / 4)

        func project(_ point: CGPoint) -> CGPoint {
            let x = point.x - pivot.x
            let y = -(point.y - pivot.y)
            let tiltedX = x * cosY + y * sinX * sinY
            let tiltedY = y * cosX
            let depth = -x * sinY + y * sinX * cosY
            let scale = focalLength / (focalLength + depth)
            let projectedX = tiltedX * scale
            let projectedY = -tiltedY * scale
            return CGPoint(
                x: pivot.x + projectedX * cosZ - projectedY * sinZ,
                y: pivot.y + projectedX * sinZ + projectedY * cosZ
            )
        }

        return TextTiltCorners(
            topLeft: project(CGPoint(x: rect.minX, y: rect.minY)),
            topRight: project(CGPoint(x: rect.maxX, y: rect.minY)),
            bottomRight: project(CGPoint(x: rect.maxX, y: rect.maxY)),
            bottomLeft: project(CGPoint(x: rect.minX, y: rect.maxY))
        )
    }

    private static func sinCos(_ degrees: Double) -> (sin: CGFloat, cos: CGFloat) {
        let radians = CGFloat(degrees * .pi / 180)
        return (sin(radians), cos(radians))
    }
}
