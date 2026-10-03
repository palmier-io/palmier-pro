import Foundation

enum HostedServices {
    static let enabled = false

    @MainActor
    static var generationAvailability: RuntimeCapability {
        availability(needsCredits: true, needsCatalog: true)
    }

    @MainActor
    static var cloudTranscriptionAvailability: RuntimeCapability {
        availability(needsCredits: true, needsCatalog: false)
    }

    @MainActor
    static var accessAvailability: RuntimeCapability {
        availability(needsCredits: false, needsCatalog: false)
    }

    @MainActor
    private static func availability(needsCredits: Bool, needsCatalog: Bool) -> RuntimeCapability {
        let account = AccountService.shared
        return RuntimeCapabilities.hostedGeneration(
            enabled: enabled,
            configured: !account.isMisconfigured && account.convex != nil,
            signedIn: account.isSignedIn,
            hasCredits: !needsCredits || account.hasCredits,
            catalogLoaded: !needsCatalog || ModelCatalog.shared.isLoaded
        )
    }

}
