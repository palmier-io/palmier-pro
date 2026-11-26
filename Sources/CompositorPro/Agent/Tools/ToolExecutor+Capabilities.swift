import Foundation

extension ToolExecutor {
    func getCapabilities(_ args: [String: Any], externalClient: Bool) async -> ToolResult {
        do {
            try validateUnknownKeys(args, allowed: [], path: "get_capabilities")
            let local = try await capabilityInputLoader()
            try Task.checkCancellation()
            let supportsImages = externalClient ? nil : editor?.agentService.snapshotRunSettings().supportsImages
            let receipt = RuntimeCapabilities.receipt(
                local: local, visualModel: visualSearchModel, imageInputSupported: supportsImages,
                hosted: HostedServices.generationAvailability,
                cloudTranscription: HostedServices.cloudTranscriptionAvailability,
                denoising: AudioEnhancer.availability
            )
            guard let json = Self.jsonString(receipt) else { return .error("Failed to encode capabilities.") }
            return .ok(json)
        } catch is CancellationError {
            return .error("Capability inspection cancelled.")
        } catch let error as ToolError {
            return .error(error.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }
}
