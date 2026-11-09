import Foundation

/// Hosted services were removed in the backend teardown (R1). Everything runs
/// locally now; hosted generation/transcription are reported unavailable with a
/// stable reason instead of pretending to reach a server.
enum HostedServices {
    static let enabled = false

    static var generationAvailability: RuntimeCapability {
        RuntimeCapability(status: .unavailable, reason: .hostedBuildExcluded)
    }

    static var cloudTranscriptionAvailability: RuntimeCapability {
        RuntimeCapability(status: .unavailable, reason: .hostedBuildExcluded)
    }

    static var accessAvailability: RuntimeCapability {
        RuntimeCapability(status: .available)
    }
}
