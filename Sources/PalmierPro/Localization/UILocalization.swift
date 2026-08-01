extension ClipType {
    @MainActor
    var localizedTrackLabel: String {
        switch self {
        case .video, .sequence: L10n.string("Video")
        case .audio: L10n.string("Audio")
        case .image: L10n.string("Image")
        case .text: L10n.string("Text")
        case .lottie: "Lottie"
        }
    }
}

extension AudioModelConfig.Category {
    @MainActor
    var localizedLabel: String {
        switch self {
        case .general: L10n.string("General")
        case .tts: L10n.string("Speech")
        case .music: L10n.string("Music")
        case .sfx: L10n.string("Sound Effects")
        case .cleanup: L10n.string("Voice Cleanup")
        case .dubbing: L10n.string("Dubbing")
        }
    }
}

extension CropAspectLock {
    @MainActor
    var localizedLabel: String {
        switch self {
        case .free: L10n.string("Custom")
        case .original: L10n.string("Original")
        case .r16x9, .r9x16, .r1x1, .r4x3, .r3x4, .r21x9: label
        }
    }
}
