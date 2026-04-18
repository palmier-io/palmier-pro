enum ClipType: String, Codable, Sendable, CaseIterable {
    case video
    case audio
    case image

    var sfSymbolName: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        }
    }

    var trackLabel: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        }
    }

    var trackLabelPrefix: String { String(trackLabel.prefix(1)) }

    var isVisual: Bool {
        self == .video || self == .image
    }

    func isCompatible(with other: ClipType) -> Bool {
        self == other || (self.isVisual && other.isVisual)
    }

    init?(fileExtension ext: String) {
        switch ext {
        case "mov", "mp4", "m4v": self = .video
        case "mp3", "wav", "aac", "m4a": self = .audio
        case "png", "jpg", "jpeg", "tiff", "heic": self = .image
        default: return nil
        }
    }
}
