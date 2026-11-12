import Foundation

extension ToolExecutor {
    private struct MixAudioInput: DecodableToolArgs {
        let roles: [AudioRoleAssignment]
        let targetLUFS: Double
        let truePeakDBTP: Double
        let toleranceLU: Double?
        let voiceDenoiseAmount: Double?
        let bedFadeFrames: Int?
        let duckDb: Double?
        let attackFrames: Int?
        let holdFrames: Int?
        let releaseFrames: Int?
        let mergeGapFrames: Int?
        let replaceAutomation: Bool?

        static let allowedKeys: Set<String> = [
            "roles", "targetLUFS", "truePeakDBTP", "toleranceLU", "voiceDenoiseAmount", "bedFadeFrames",
            "duckDb", "attackFrames", "holdFrames", "releaseFrames", "mergeGapFrames", "replaceAutomation",
        ]
    }

    func mixAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        if let roles = args["roles"] as? [[String: Any]] {
            for (index, role) in roles.enumerated() {
                try validateUnknownKeys(role, allowed: ["clipId", "role", "targetLUFS", "peakDBFS"], path: "mix_audio.roles[\(index)]")
            }
        }
        let input: MixAudioInput = try decodeToolArgs(args, path: "mix_audio")
        let fps = editor.timeline.fps
        guard (1...120).contains(fps) else { throw ToolError("mix_audio: invalid timeline frame rate") }
        let request = AudioMixRequest(
            roles: input.roles,
            target: .init(integratedLUFS: input.targetLUFS, truePeakDBTP: input.truePeakDBTP, toleranceLU: input.toleranceLU ?? 1),
            ducking: .init(duckDb: input.duckDb ?? -12, attackFrames: input.attackFrames ?? max(1, fps / 5),
                          holdFrames: input.holdFrames ?? max(1, fps / 5), releaseFrames: input.releaseFrames ?? max(1, fps * 3 / 5),
                          mergeGapFrames: input.mergeGapFrames ?? max(1, fps * 2 / 5)),
            bedFadeFrames: input.bedFadeFrames ?? max(1, fps / 2), voiceDenoiseAmount: input.voiceDenoiseAmount
        )
        do {
            let result = try await editor.mixAudio(request: request, replaceAutomation: input.replaceAutomation ?? false, finish: audioMixFinishing)
            guard let json = Self.jsonString(result.receipt) else { throw ToolError("mix_audio: failed to encode its terminal receipt") }
            return .ok(json)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ToolError("mix_audio: \(error.localizedDescription)")
        }
    }
}
