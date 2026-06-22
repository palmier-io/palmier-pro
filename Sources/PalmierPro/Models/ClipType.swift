enum ClipType: String, Codable, Sendable, CaseIterable {
    case video
    case audio
    case image
    case text
    case lottie

    var sfSymbolName: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        case .text: "textformat"
        case .lottie: "sparkles"
        }
    }

    var trackLabel: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        case .text: "Text"
        case .lottie: "Lottie"
        }
    }

    var trackLabelPrefix: String { String(trackLabel.prefix(1)) }

    var isVisual: Bool {
        self == .video || self == .image || self == .text || self == .lottie
    }

    func isCompatible(with other: ClipType) -> Bool {
        self == other || (self.isVisual && other.isVisual)
    }

    init?(fileExtension ext: String) {
        switch ext {
        case "mov", "mp4", "m4v": self = .video
        case "mp3", "wav", "aac", "m4a", "aiff", "aif", "aifc", "flac": self = .audio
        case "png", "jpg", "jpeg", "tiff", "heic", "webp": self = .image
        case "json", "lottie": self = .lottie
        default: return nil
        }
    }
}
