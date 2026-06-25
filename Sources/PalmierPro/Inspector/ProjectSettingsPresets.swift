// Shared presets for editable project settings (used by the inspector's Format section).

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
        case .twoPointFourOne: 2560
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

    /// Scale resolution while preserving the current aspect ratio.
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

    private var shortEdge: Int {
        switch self {
        case .hd720: 720
        case .fullHD: 1080
        case .twoK: 1440
        case .fourK: 2160
        }
    }
}
