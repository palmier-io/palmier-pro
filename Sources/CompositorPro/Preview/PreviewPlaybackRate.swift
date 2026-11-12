enum PreviewPlaybackRate: Float, CaseIterable, Sendable {
    case half = 0.5
    case threeQuarters = 0.75
    case normal = 1
    case oneAndHalf = 1.5
    case double = 2
    case quadruple = 4
    case tenfold = 10

    var label: String {
        switch self {
        case .half: "0.5×"
        case .threeQuarters: "0.75×"
        case .normal: "1×"
        case .oneAndHalf: "1.5×"
        case .double: "2×"
        case .quadruple: "4×"
        case .tenfold: "10×"
        }
    }

    var allowsAudioMetering: Bool {
        switch self {
        case .half, .threeQuarters, .normal, .oneAndHalf, .double: true
        case .quadruple, .tenfold: false
        }
    }
}
