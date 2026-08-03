import Testing
@testable import PalmierPro

@Suite struct AppCapabilitiesTests {
    @Test func intelDisablesArchitectureLimitedFeatures() {
        let capabilities = AppCapabilities(
            architecture: .x86_64,
            includesBundledSpeech: true,
            includesHostedBackend: true,
            hasPackagedSpeechResources: true
        )

        #expect(capabilities.availability(of: .silenceDetection) == .unavailable(.requiresAppleSilicon))
        #expect(capabilities.availability(of: .hostedServices) == .unavailable(.requiresAppleSilicon))
    }

    @Test func armBuildRequiresExplicitOptionalFeatures() {
        let capabilities = AppCapabilities(
            architecture: .arm64,
            includesBundledSpeech: false,
            includesHostedBackend: false,
            hasPackagedSpeechResources: false
        )

        #expect(capabilities.availability(of: .silenceDetection) == .unavailable(.buildExcludesBundledSpeech))
        #expect(capabilities.availability(of: .hostedServices) == .unavailable(.buildExcludesHostedBackend))
    }

    @Test func configuredArmBuildEnablesOptionalFeatures() {
        let capabilities = AppCapabilities(
            architecture: .arm64,
            includesBundledSpeech: true,
            includesHostedBackend: true,
            hasPackagedSpeechResources: true
        )

        #expect(capabilities.availability(of: .silenceDetection) == .available)
        #expect(capabilities.availability(of: .hostedServices) == .available)
    }
}
