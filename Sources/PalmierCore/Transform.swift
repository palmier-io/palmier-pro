import Foundation

public struct Transform: Codable, Sendable, Equatable, Hashable {
    public var centerX: Double = 0.5
    public var centerY: Double = 0.5
    public var width: Double = 1
    public var height: Double = 1
    public var rotation: Double = 0 // degrees, positive = clockwise
    public var flipHorizontal: Bool = false
    public var flipVertical: Bool = false

    public var topLeft: (x: Double, y: Double) {
        (centerX - width / 2, centerY - height / 2)
    }

    public var center: (x: Double, y: Double) {
        (centerX, centerY)
    }

    public init(
        centerX: Double = 0.5,
        centerY: Double = 0.5,
        width: Double = 1,
        height: Double = 1,
        rotation: Double = 0,
        flipHorizontal: Bool = false,
        flipVertical: Bool = false
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
        self.rotation = rotation
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    public init(topLeft tl: (x: Double, y: Double), width w: Double, height h: Double) {
        self.centerX = tl.x + w / 2
        self.centerY = tl.y + h / 2
        self.width = w
        self.height = h
    }

    public init(center c: (x: Double, y: Double), width w: Double, height h: Double) {
        self.centerX = c.x
        self.centerY = c.y
        self.width = w
        self.height = h
    }

    private enum CodingKeys: String, CodingKey {
        case centerX, centerY, width, height, rotation, flipHorizontal, flipVertical
        // Legacy keys
        case x, y
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let w = try c.decodeIfPresent(Double.self, forKey: .width) ?? 1
        let h = try c.decodeIfPresent(Double.self, forKey: .height) ?? 1
        if let cx = try c.decodeIfPresent(Double.self, forKey: .centerX) {
            self.centerX = cx
        } else if let oldX = try c.decodeIfPresent(Double.self, forKey: .x) {
            self.centerX = oldX + w - 0.5
        } else {
            self.centerX = 0.5
        }
        if let cy = try c.decodeIfPresent(Double.self, forKey: .centerY) {
            self.centerY = cy
        } else if let oldY = try c.decodeIfPresent(Double.self, forKey: .y) {
            self.centerY = oldY + h - 0.5
        } else {
            self.centerY = 0.5
        }
        self.width = w
        self.height = h
        self.rotation = try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        self.flipHorizontal = try c.decodeIfPresent(Bool.self, forKey: .flipHorizontal) ?? false
        self.flipVertical = try c.decodeIfPresent(Bool.self, forKey: .flipVertical) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(centerX, forKey: .centerX)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(flipHorizontal, forKey: .flipHorizontal)
        try c.encode(flipVertical, forKey: .flipVertical)
    }

    /// Snap a value to canvas boundaries (0 or 1) within threshold.
    public static func snapToBoundary(_ value: Double, threshold: Double) -> Double {
        if abs(value) < threshold { return 0 }
        if abs(value - 1) < threshold { return 1 }
        return value
    }

    /// Snap clip edges to canvas boundaries (0 or 1).
    public mutating func snapToCanvasEdges(threshold: Double) {
        let tl = topLeft
        let snappedLeft = Self.snapToBoundary(tl.x, threshold: threshold)
        let snappedRight = Self.snapToBoundary(tl.x + width, threshold: threshold)
        if snappedLeft != tl.x {
            centerX -= (tl.x - snappedLeft)
        } else if snappedRight != tl.x + width {
            centerX -= (tl.x + width - snappedRight)
        }

        let tl2 = topLeft
        let snappedTop = Self.snapToBoundary(tl2.y, threshold: threshold)
        let snappedBottom = Self.snapToBoundary(tl2.y + height, threshold: threshold)
        if snappedTop != tl2.y {
            centerY -= (tl2.y - snappedTop)
        } else if snappedBottom != tl2.y + height {
            centerY -= (tl2.y + height - snappedBottom)
        }
    }

    /// Snap per-axis within threshold. Return tuple lets callers draw guide indicators.
    @discardableResult
    public mutating func snapCenterToCanvasCenter(thresholdH: Double, thresholdV: Double) -> (x: Bool, y: Bool) {
        var snappedX = false
        var snappedY = false
        if abs(centerX - 0.5) < thresholdH {
            centerX = 0.5
            snappedX = true
        }
        if abs(centerY - 0.5) < thresholdV {
            centerY = 0.5
            snappedY = true
        }
        return (snappedX, snappedY)
    }
}

/// Per-clip crop as edge insets in normalized (0–1) source coordinates.
public struct Crop: Codable, Sendable, Equatable {
    public var left: Double = 0
    public var top: Double = 0
    public var right: Double = 0
    public var bottom: Double = 0

    public init(left: Double = 0, top: Double = 0, right: Double = 0, bottom: Double = 0) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var isIdentity: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
    public var visibleWidthFraction: Double { max(0, 1 - left - right) }
    public var visibleHeightFraction: Double { max(0, 1 - top - bottom) }
}

/// Aspect-ratio constraint for the Crop overlay.
public enum CropAspectLock: Hashable, CaseIterable, Sendable {
    case free, original, r16x9, r9x16, r1x1, r4x3, r3x4, r21x9

    public var label: String {
        switch self {
        case .free: "Custom"
        case .original: "Original"
        case .r16x9: "16:9"
        case .r9x16: "9:16"
        case .r1x1: "1:1"
        case .r4x3: "4:3"
        case .r3x4: "3:4"
        case .r21x9: "21:9"
        }
    }

    public var pixelAspect: Double? {
        switch self {
        case .free, .original: nil
        case .r16x9: 16.0 / 9.0
        case .r9x16: 9.0 / 16.0
        case .r1x1: 1.0
        case .r4x3: 4.0 / 3.0
        case .r3x4: 3.0 / 4.0
        case .r21x9: 21.0 / 9.0
        }
    }
}
