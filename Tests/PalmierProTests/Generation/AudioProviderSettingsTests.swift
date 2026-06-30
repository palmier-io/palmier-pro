import Foundation
import Testing
@testable import PalmierPro

@Suite("Audio provider settings")
struct AudioProviderSettingsTests {
    @Test func miniMaxRegionSelectsDomesticAndInternationalEndpoints() {
        #expect(MiniMaxAPIRegion.mainlandChina.modelsURL.absoluteString == "https://api.minimaxi.com/v1/models")
        #expect(MiniMaxAPIRegion.mainlandChina.musicGenerationURL.absoluteString == "https://api.minimaxi.com/v1/music_generation")
        #expect(MiniMaxAPIRegion.global.modelsURL.absoluteString == "https://api.minimax.io/v1/models")
        #expect(MiniMaxAPIRegion.global.musicGenerationURL.absoluteString == "https://api.minimax.io/v1/music_generation")
    }

    @Test func miniMaxStoredModelIdsKeepProviderBoundary() {
        #expect(MiniMaxModelId.stored("music-2.6") == "minimax:music-2.6")
        #expect(MiniMaxModelId.stored("minimax:music-2.6") == "minimax:music-2.6")
        #expect(MiniMaxModelId.raw("minimax:music-2.6") == "music-2.6")
        #expect(MiniMaxModelId.raw("music-2.6") == nil)
    }

    @Test func miniMaxServiceMapsLegacyCatalogModelToOfficialModelId() {
        let model = audioModel(id: "minimax-music-v2.6", displayName: "MiniMax Music v2.6")
        #expect(MiniMaxAudioService.apiModelId(for: model) == "music-2.6")
    }

    @Test func miniMaxModelEndpointFallbackKeepsMusicGenerationModelsAvailable() {
        let response: [String: Any] = [
            "data": [
                ["id": "abab6.5s-chat"],
                ["id": "speech-2.5-hd-preview"],
            ],
        ]

        #expect(AudioProviderCatalog.miniMaxModelIds(from: response) == ["music-2.6-free", "music-2.6"])
    }

    @Test func miniMaxModelEndpointKeepsOnlySupportedMusicGenerationModels() {
        let response: [String: Any] = [
            "data": [
                ["id": "music-cover"],
                ["id": "music-2.6"],
                ["id": "music-2.6-free"],
            ],
        ]

        #expect(AudioProviderCatalog.miniMaxModelIds(from: response) == ["music-2.6-free", "music-2.6"])
    }

    private func audioModel(id: String, displayName: String) -> AudioModelConfig {
        let caps = AudioCaps(
            category: "music",
            voices: nil,
            defaultVoice: nil,
            supportsLyrics: true,
            supportsInstrumental: true,
            supportsStyleInstructions: false,
            durations: nil,
            minPromptLength: 10,
            inputs: ["text"],
            promptLabel: nil,
            minSeconds: nil,
            maxSeconds: nil
        )
        let entry = CatalogEntry(
            id: id,
            kind: .audio,
            displayName: displayName,
            allowedEndpoints: ["minimax"],
            responseShape: .audio,
            uiCapabilities: .audio(caps)
        )
        return AudioModelConfig(entry: entry, caps: caps)
    }
}
