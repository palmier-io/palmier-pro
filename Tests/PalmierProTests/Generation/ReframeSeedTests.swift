import Foundation
import Testing
@testable import PalmierPro

@Suite("Reframe seed")
@MainActor
struct ReframeSeedTests {
    @Test("Seeds MiniMax H3 with video reference and fill prompt")
    func seedsVideoReferenceAndPrompt() throws {
        let model = try Self.minimaxH3()
        let asset = MediaAsset(
            id: "clip-1",
            url: URL(fileURLWithPath: "/tmp/wide.mp4"),
            type: .video,
            name: "Wide",
            duration: 8.2
        )
        asset.sourceWidth = 1920
        asset.sourceHeight = 1080

        let seed = try #require(EditSubmitter.reframeSeed(for: asset, model: model))

        #expect(seed.model == "minimax-h3")
        #expect(seed.prompt == EditSubmitter.reframePrompt)
        #expect(seed.prompt.contains("@Video1"))
        #expect(seed.aspectRatio == "9:16")
        #expect(seed.resolution == "2K")
        #expect(seed.duration == 9)
        #expect(seed.referenceVideoAssetIds == ["clip-1"])
        #expect(seed.imageURLAssetIds == nil)
    }

    @Test("Portrait sources reframe to landscape")
    func flipsPortraitToLandscape() throws {
        let model = try Self.minimaxH3()
        let asset = MediaAsset(
            id: "clip-2",
            url: URL(fileURLWithPath: "/tmp/tall.mp4"),
            type: .video,
            name: "Tall",
            duration: 5
        )
        asset.sourceWidth = 1080
        asset.sourceHeight = 1920

        let seed = try #require(EditSubmitter.reframeSeed(for: asset, model: model))
        #expect(seed.aspectRatio == "16:9")
    }

    @Test("Rejects models that cannot take video references")
    func rejectsSourceOnlyModels() throws {
        let model = try Self.sourceEditModel()
        let asset = MediaAsset(
            id: "clip-3",
            url: URL(fileURLWithPath: "/tmp/clip.mp4"),
            type: .video,
            name: "Clip",
            duration: 5
        )
        #expect(EditSubmitter.reframeSeed(for: asset, model: model) == nil)
        #expect(!VideoModelConfig.isReframeModel(model))
    }

    @Test("Duration covers the source span so the replaced clip never outlives the media")
    func durationCoversSourceSpan() throws {
        let model = try Self.minimaxH3()
        #expect(model.supportedDuration(covering: 7.6) == 8)
        #expect(model.supportedDuration(covering: 8.5) == 9)
        #expect(model.supportedDuration(covering: 4.1) == 5)
        #expect(model.supportedDuration(covering: 10) == 10)
        #expect(model.supportedDuration(covering: 20) == 15)
        #expect(model.validateReframeDuration(16) != nil)
        #expect(model.validateReframeDuration(10) == nil)
    }

    @Test("Validates combined video-ref duration against the trimmed span")
    func validateUsesTrimmedVideoRefDuration() throws {
        let model = try Self.minimaxH3()
        let url = URL(fileURLWithPath: "/tmp/long-reframe.mp4")
        let asset = MediaAsset(
            id: "long-1",
            url: url,
            type: .video,
            name: "Long",
            duration: 60
        )
        let inputs = VideoGenerationSubmission.InputAssets(videoRefs: [asset])
        #expect(inputs.validate(for: model)?.contains("Combined video reference duration") == true)

        let trim = TrimmedSource(
            sourceURL: url,
            trimStartFrame: 0,
            trimEndFrame: 45 * 30,
            sourceFramesConsumed: 10 * 30,
            fps: 30
        )
        #expect(trim.durationSeconds == 10)
        #expect(inputs.validate(for: model, trimmedSource: trim) == nil)
    }

    @Test("Applies trim to the matching video even when an image reference precedes it")
    func validateAppliesTrimBehindImageReference() throws {
        let model = try Self.minimaxH3()
        let image = MediaAsset(
            id: "img-1",
            url: URL(fileURLWithPath: "/tmp/style.png"),
            type: .image,
            name: "Style"
        )
        let videoURL = URL(fileURLWithPath: "/tmp/long-second.mp4")
        let video = MediaAsset(
            id: "vid-2",
            url: videoURL,
            type: .video,
            name: "Long second",
            duration: 60
        )
        let inputs = VideoGenerationSubmission.InputAssets(
            imageRefs: [image],
            videoRefs: [video]
        )
        let trim = TrimmedSource(
            sourceURL: videoURL,
            trimStartFrame: 30,
            trimEndFrame: 49 * 30,
            sourceFramesConsumed: 10 * 30,
            fps: 30
        )
        #expect(inputs.validate(for: model, trimmedSource: trim) == nil)
    }

    @Test("Ignores trim whose source URL matches no reference")
    func validateIgnoresUnrelatedTrim() throws {
        let model = try Self.minimaxH3()
        let video = MediaAsset(
            id: "vid-3",
            url: URL(fileURLWithPath: "/tmp/long-third.mp4"),
            type: .video,
            name: "Long third",
            duration: 60
        )
        let inputs = VideoGenerationSubmission.InputAssets(videoRefs: [video])
        let trim = TrimmedSource(
            sourceURL: URL(fileURLWithPath: "/tmp/other.mp4"),
            trimStartFrame: 30,
            trimEndFrame: 49 * 30,
            sourceFramesConsumed: 10 * 30,
            fps: 30
        )
        #expect(inputs.validate(for: model, trimmedSource: trim)?.contains("Combined video reference duration") == true)
    }

    private static func minimaxH3() throws -> VideoModelConfig {
        try decodeVideoModel(#"""
        {
          "id": "minimax-h3",
          "kind": "video",
          "displayName": "MiniMax H3",
          "providerIconKey": "minimax",
          "allowedEndpoints": ["opaque"],
          "responseShape": "video",
          "uiCapabilities": {
            "supportsPrompt": true,
            "durations": [5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
            "resolutions": ["768P", "2K"],
            "aspectRatios": ["16:9", "9:16", "1:1"],
            "supportsFirstFrame": false,
            "supportsLastFrame": false,
            "maxReferenceImages": 9,
            "maxReferenceVideos": 3,
            "maxReferenceAudios": 3,
            "maxTotalReferences": 12,
            "maxCombinedVideoRefSeconds": 15,
            "maxCombinedAudioRefSeconds": 15,
            "framesAndReferencesExclusive": false,
            "referenceTagNoun": "Video",
            "requiresSourceVideo": false,
            "maxSourceVideoSeconds": null,
            "requiresReferenceImage": false,
            "requiresReferenceAudio": false
          }
        }
        """#)
    }

    private static func sourceEditModel() throws -> VideoModelConfig {
        try decodeVideoModel(#"""
        {
          "id": "kling-reframe",
          "kind": "video",
          "displayName": "Legacy Reframe",
          "allowedEndpoints": ["opaque"],
          "responseShape": "video",
          "uiCapabilities": {
            "supportsPrompt": true,
            "durations": [5, 10],
            "resolutions": ["1080p"],
            "aspectRatios": ["16:9", "9:16"],
            "supportsFirstFrame": false,
            "supportsLastFrame": false,
            "maxReferenceImages": 0,
            "maxReferenceVideos": 0,
            "maxReferenceAudios": 0,
            "maxTotalReferences": null,
            "maxCombinedVideoRefSeconds": null,
            "maxCombinedAudioRefSeconds": null,
            "framesAndReferencesExclusive": false,
            "referenceTagNoun": "Video",
            "requiresSourceVideo": true,
            "maxSourceVideoSeconds": 10,
            "requiresReferenceImage": false,
            "requiresReferenceAudio": false
          }
        }
        """#)
    }

    private static func decodeVideoModel(_ json: String) throws -> VideoModelConfig {
        let entry = try JSONDecoder().decode(CatalogEntry.self, from: Data(json.utf8))
        guard case .video(let caps) = entry.uiCapabilities else {
            Issue.record("Expected video capabilities")
            throw DecodeError.wrongKind
        }
        return VideoModelConfig(entry: entry, caps: caps)
    }

    private enum DecodeError: Error { case wrongKind }
}
