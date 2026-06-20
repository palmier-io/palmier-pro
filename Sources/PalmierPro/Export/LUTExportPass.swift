import AVFoundation
import CoreImage

/// Grades the flattened export via `applyingCIFiltersWithHandler` (the compositor has no color hook).
/// The filter chain already bakes in LUT intensity, so this is a straight apply.
enum LUTExportPass {
    static func apply(
        processor: ColorGradeProcessor,
        to inputURL: URL,
        fileType: AVFileType,
        preset: String
    ) async throws -> URL {
        let colorSpace = GradePipeline.workingColorSpace
        let asset = AVURLAsset(url: inputURL)

        let videoComposition = try await AVVideoComposition.videoComposition(
            with: asset
        ) { request in
            let graded = processor.process(request.sourceImage.clampedToExtent(), colorSpace: colorSpace)
            request.finish(with: graded.cropped(to: request.sourceImage.extent), context: nil)
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw LUTPassError.unsupportedPreset
        }
        session.videoComposition = videoComposition

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("grade-pass-\(UUID().uuidString).\(inputURL.pathExtension)")
        try? FileManager.default.removeItem(at: outputURL)

        Log.export.notice("grade-pass start")
        try await session.export(to: outputURL, as: fileType)
        Log.export.notice("grade-pass ok url=\(outputURL.lastPathComponent)")
        return outputURL
    }

    enum LUTPassError: LocalizedError {
        case unsupportedPreset
        var errorDescription: String? {
            switch self {
            case .unsupportedPreset: "Export preset unsupported for the color pass"
            }
        }
    }
}
