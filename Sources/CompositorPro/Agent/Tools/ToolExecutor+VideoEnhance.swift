import AVFoundation
import CoreGraphics
import CoreImage
import Foundation

extension ToolExecutor {
    fileprivate struct EnhanceMediaInput: DecodableToolArgs {
        let clipIds: [String]
        let scale: String?
        let approved: Bool?
        static let allowedKeys: Set<String> = ["clipIds", "scale", "approved"]
    }

    func enhanceMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let input: EnhanceMediaInput = try decodeToolArgs(args, path: "enhance_media")
        guard !input.clipIds.isEmpty else { throw ToolError("clipIds is empty.") }

        let scale = LocalVideoUpscaler.Scale(rawValue: input.scale ?? "2x") ?? .x2
        let approved = input.approved ?? false

        var clips: [Clip] = []
        var assets: [MediaAsset] = []
        for id in input.clipIds {
            guard let clip = editor.clipFor(id: id) else { throw ToolError("Clip not found: \(id)") }
            guard clip.mediaType.isVisual else {
                throw ToolError("Clip \(id) is a \(clip.mediaType.rawValue) clip; enhance_media needs a video or image clip.")
            }
            guard let asset = editor.mediaAssets.first(where: { $0.id == clip.mediaRef }) else {
                throw ToolError("Source asset not found for clip \(id).")
            }
            guard asset.sourceWidth != nil, asset.sourceHeight != nil else {
                throw ToolError("Source dimensions not available for \(asset.name). Wait for media to load.")
            }
            clips.append(clip)
            assets.append(asset)
        }

        if approved {
            return try await performEnhancement(editor: editor, clips: clips, assets: assets, scale: scale)
        }

        let previewResult = try await generatePreviews(editor: editor, clips: clips, assets: assets, scale: scale)
        return previewResult
    }

    private func generatePreviews(
        editor: EditorViewModel, clips: [Clip], assets: [MediaAsset], scale: LocalVideoUpscaler.Scale
    ) async throws -> ToolResult {
        var previewBlocks: [ToolResult.Block] = []
        var meta: [[String: Any]] = []

        for (clip, asset) in zip(clips, assets) {
            let previewFrames = try await extractPreviewFrames(
                editor: editor, clip: clip, asset: asset, scale: scale
            )
            previewBlocks.append(contentsOf: previewBlocksFrom(frames: previewFrames))
            meta.append([
                "clipId": clip.id,
                "assetId": asset.id,
                "assetName": asset.name,
                "sourceWidth": asset.sourceWidth ?? 0,
                "sourceHeight": asset.sourceHeight ?? 0,
                "scale": scale.rawValue,
                "targetWidth": (asset.sourceWidth ?? 0) * scale.factor,
                "targetHeight": (asset.sourceHeight ?? 0) * scale.factor,
            ])
        }

        let metaJSON = Self.jsonString(meta) ?? "[]"
        return ToolResult(content: previewBlocks + [.text(metaJSON)], isError: false)
    }

    private func extractPreviewFrames(
        editor: EditorViewModel, clip: Clip, asset: MediaAsset, scale: LocalVideoUpscaler.Scale
    ) async throws -> [(before: CGImage, after: CGImage)] {
        let sourceWidth = asset.sourceWidth!
        let sourceHeight = asset.sourceHeight!
        let targetWidth = sourceWidth * scale.factor
        let targetHeight = sourceHeight * scale.factor

        let fps = editor.timeline.fps
        let clipStart = clip.startFrame
        let clipDuration = clip.durationFrames
        let sampleFrames = min(4, clipDuration > 0 ? clipDuration : 1)
        var frames: [(before: CGImage, after: CGImage)] = []

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
        generator.appliesPreferredTrackTransform = true

        for i in 0..<sampleFrames {
            try Task.checkCancellation()
            let frameIndex = clipStart + (clipDuration * (i + 1) / (sampleFrames + 1))
            let time = Double(frameIndex) / Double(fps)
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            guard let beforeImage = try? await generator.image(at: cmTime).image else { continue }

            let afterImage = try LocalVideoUpscaler.upscaleCGImage(
                CIImage(cgImage: beforeImage),
                to: CGSize(width: targetWidth, height: targetHeight)
            )
            frames.append((before: beforeImage, after: afterImage))
        }
        return frames
    }

    private func previewBlocksFrom(frames: [(before: CGImage, after: CGImage)]) -> [ToolResult.Block] {
        var blocks: [ToolResult.Block] = []
        for (index, (before, after)) in frames.enumerated() {
            if let beforeData = InspectFrameOverlay.encode(before, caption: "Original (frame \(index))") {
                blocks.append(.image(base64: beforeData.data.base64EncodedString(), mediaType: beforeData.mime))
            }
            if let afterData = InspectFrameOverlay.encode(after, caption: "Enhanced \(LocalVideoUpscaler.Scale.x2.rawValue) (frame \(index))") {
                blocks.append(.image(base64: afterData.data.base64EncodedString(), mediaType: afterData.mime))
            }
        }
        return blocks
    }

    private func performEnhancement(
        editor: EditorViewModel, clips: [Clip], assets: [MediaAsset], scale: LocalVideoUpscaler.Scale
    ) async throws -> ToolResult {
        var warnings: [String] = []
        var changedClipIds: [String] = []
        let snapshot = timelineSnapshot(editor)

        for (clip, asset) in zip(clips, assets) {
            let result = try await LocalVideoUpscaler.upscale(
                mediaRef: asset.id,
                sourceURL: asset.url,
                width: asset.sourceWidth!,
                height: asset.sourceHeight!,
                scale: scale,
                type: asset.type
            )

            // Create enhanced MediaAsset and replace the clip's media reference
            let enhancedAsset = MediaAsset(id: UUID().uuidString, url: result.outputURL, type: asset.type, name: "\(asset.name) (upscaled \(scale.rawValue))")
            enhancedAsset.sourceWidth = result.width
            enhancedAsset.sourceHeight = result.height
            enhancedAsset.sourceFPS = asset.sourceFPS
            enhancedAsset.hasAudio = asset.hasAudio
            enhancedAsset.folderId = asset.folderId
            enhancedAsset.generationInput = asset.generationInput

            let plan = try editor.swapClipMedia(
                clipId: clip.id,
                replacement: enhancedAsset,
                commit: true
            )

            if plan.changed {
                changedClipIds.append(clip.id)
            }
        }

        if changedClipIds.isEmpty {
            return ToolResult(
                content: [.text(Self.jsonString([
                    "noOp": true,
                    "message": "No clips were changed (upscale already applied or replacement identical).",
                    "warnings": warnings,
                ]) ?? "")],
                isError: false
            )
        }

        let extra: [String: Any] = [
            "enhancedClipIds": changedClipIds,
            "scale": scale.rawValue,
            "warnings": warnings,
        ]
        return mutationResult(editor, since: snapshot, touched: changedClipIds, extra: extra)
    }
}