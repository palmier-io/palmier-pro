import Foundation

struct AspectRatioError: LocalizedError {
    enum Code {
        case invalidFormat
        case resolutionTooSmall
        case resolutionTooLarge
    }

    let code: Code

    var errorDescription: String? {
        switch code {
        case .invalidFormat: "Use an aspect ratio with two positive numbers, such as 3:2."
        case .resolutionTooSmall: "Resolution must be at least 2 × 2 pixels."
        case .resolutionTooLarge: "Resolution must not exceed 8192 pixels on either edge."
        }
    }
}

struct CanvasAspectRatio: Equatable {
    let horizontal: Double
    let vertical: Double

    init(_ text: String) throws {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let horizontal = Double(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)),
              let vertical = Double(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
              horizontal.isFinite, vertical.isFinite, horizontal > 0, vertical > 0,
              (horizontal / vertical).isFinite else {
            throw AspectRatioError(code: .invalidFormat)
        }
        self.horizontal = horizontal
        self.vertical = vertical
    }

    func resolution(shortEdge: Int) throws -> (width: Int, height: Int) {
        guard shortEdge >= 2 else {
            throw AspectRatioError(code: .resolutionTooSmall)
        }
        let ratio = horizontal / vertical
        let short = shortEdge.isMultiple(of: 2) ? shortEdge : shortEdge + 1
        let longValue = Double(short) * max(ratio, 1 / ratio)
        guard longValue <= 8_192 else {
            throw AspectRatioError(code: .resolutionTooLarge)
        }
        let long = Int((longValue / 2).rounded()) * 2
        return ratio >= 1 ? (long, short) : (short, long)
    }

    static func displayLabel(width: Int, height: Int) -> String {
        guard width > 0, height > 0 else { return "—" }
        var a = width
        var b = height
        while b != 0 { (a, b) = (b, a % b) }
        let reducedWidth = width / a
        let reducedHeight = height / a
        if max(reducedWidth, reducedHeight) <= 100 {
            return "\(reducedWidth):\(reducedHeight)"
        }
        let ratio = Double(width) / Double(height)
        return ratio >= 1
            ? "\((ratio * 100).rounded() / 100):1"
            : "1:\(((1 / ratio) * 100).rounded() / 100)"
    }
}

enum AspectPreset: CaseIterable {
    case sixteenNine, nineByFourteen, nineSixteen, oneOne, fourThree, twoPointFourOne

    var label: String {
        switch self {
        case .sixteenNine: "16:9"
        case .nineByFourteen: "9:14"
        case .nineSixteen: "9:16"
        case .oneOne: "1:1"
        case .fourThree: "4:3"
        case .twoPointFourOne: "2.4:1"
        }
    }

    var width: Int {
        switch self {
        case .sixteenNine: 1920
        case .nineByFourteen: 1080
        case .nineSixteen: 1080
        case .oneOne: 1080
        case .fourThree: 1440
        case .twoPointFourOne: 2592
        }
    }

    var height: Int {
        switch self {
        case .sixteenNine: 1080
        case .nineByFourteen: 1680
        case .nineSixteen: 1920
        case .oneOne: 1080
        case .fourThree: 1080
        case .twoPointFourOne: 1080
        }
    }

    func matches(width: Int, height: Int) -> Bool {
        width == self.width && height == self.height
    }
}

enum QualityPreset: CaseIterable {
    case hd720, fullHD, twoK, fourK

    var label: String {
        switch self {
        case .hd720: "720p"
        case .fullHD: "1080p"
        case .twoK: "2K"
        case .fourK: "4K"
        }
    }

    func resolution(currentWidth: Int, currentHeight: Int) -> (width: Int, height: Int) {
        let target = shortEdge
        if currentWidth <= currentHeight {
            return (target, Int(Double(target) * Double(currentHeight) / Double(currentWidth)))
        }
        return (Int(Double(target) * Double(currentWidth) / Double(currentHeight)), target)
    }

    func matches(width: Int, height: Int) -> Bool {
        min(width, height) == shortEdge
    }

    var shortEdge: Int {
        switch self {
        case .hd720: 720
        case .fullHD: 1080
        case .twoK: 1440
        case .fourK: 2160
        }
    }
}
