import Foundation

enum AppFeature: String, Sendable {
    case audioDenoise = "audio_denoise"
    case hostedServices = "hosted_services"
    case silenceDetection = "silence_detection"
    case speakerIdentification = "speaker_identification"
}

enum AppFeatureUnavailability: String, Error, Sendable {
    case buildExcludesBundledSpeech = "build_excludes_bundled_speech"
    case buildExcludesHostedBackend = "build_excludes_hosted_backend"
    case requiresAppleSilicon = "requires_apple_silicon"
    case unpackagedSpeechResources = "unpackaged_speech_resources"
}

enum AppFeatureAvailability: Equatable, Sendable {
    case available
    case unavailable(AppFeatureUnavailability)

    var isAvailable: Bool {
        self == .available
    }
}

struct AppCapabilities: Sendable {
    enum Architecture: Sendable {
        case arm64
        case x86_64
        case other
    }

    let architecture: Architecture
    let includesBundledSpeech: Bool
    let includesHostedBackend: Bool
    let hasPackagedSpeechResources: Bool

    static let current = AppCapabilities(
        architecture: currentArchitecture,
        includesBundledSpeech: includesBundledSpeech,
        includesHostedBackend: includesHostedBackend,
        hasPackagedSpeechResources: Bundle.main.object(forInfoDictionaryKey: "PalmierBundledSpeech") as? Bool == true
    )

    func availability(of feature: AppFeature) -> AppFeatureAvailability {
        switch feature {
        case .audioDenoise, .silenceDetection, .speakerIdentification:
            return bundledSpeechAvailability
        case .hostedServices:
            return hostedServicesAvailability
        }
    }

    private var hostedServicesAvailability: AppFeatureAvailability {
        guard architecture == .arm64 else {
            return .unavailable(.requiresAppleSilicon)
        }
        guard includesHostedBackend else {
            return .unavailable(.buildExcludesHostedBackend)
        }
        return .available
    }

    private var bundledSpeechAvailability: AppFeatureAvailability {
        guard architecture == .arm64 else {
            return .unavailable(.requiresAppleSilicon)
        }
        guard includesBundledSpeech else {
            return .unavailable(.buildExcludesBundledSpeech)
        }
        guard hasPackagedSpeechResources else {
            return .unavailable(.unpackagedSpeechResources)
        }
        return .available
    }

    private static var currentArchitecture: Architecture {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .other
        #endif
    }

    private static var includesBundledSpeech: Bool {
        #if BUNDLED_SPEECH && arch(arm64)
        true
        #else
        false
        #endif
    }

    private static var includesHostedBackend: Bool {
        #if HOSTED_BACKEND && arch(arm64)
        true
        #else
        false
        #endif
    }
}
