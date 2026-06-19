import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

extension ToolExecutor {
    private static let importImageSequenceAllowedKeys: Set<String> =
        ["directory", "paths", "framesPerImage", "fps", "name", "folderId",
         "addToTimeline", "startFrame", "trackIndex"]
    private static let imageSequenceExtensions: Set<String> = ["png", "jpg", "jpeg", "tiff", "heic"]
    static let imageSequenceMaxImages = 5000
    static let imageSequenceMaxTotalFrames = 216_000   // 1 hour at 60 fps — runaway guard

    /// Assembles an ordered set of stills into a single H.264 video and registers it as a media
    /// asset. Fills the gap left by `import_media` (one file at a time, no frames-to-video step).
    func importImageSequence(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: Self.importImageSequenceAllowedKeys, path: "import_image_sequence")

        let directory = args.string("directory")
        let paths = args.stringArray("paths")
        guard (directory != nil) != !paths.isEmpty else {
            throw ToolError("Provide exactly one of 'directory' or 'paths'.")
        }

        let imageURLs = try Self.resolveImageURLs(directory: directory, paths: paths)
        guard !imageURLs.isEmpty else {
            throw ToolError("No supported image files found (png, jpg, jpeg, tiff, heic).")
        }
        guard imageURLs.count <= Self.imageSequenceMaxImages else {
            throw ToolError("Too many images (\(imageURLs.count); max \(Self.imageSequenceMaxImages)).")
        }

        let fps = max(1, args.int("fps") ?? editor.timeline.fps)
        let framesPerImage = max(1, args.int("framesPerImage") ?? editor.timeline.fps)
        let totalFrames = imageURLs.count * framesPerImage
        guard totalFrames <= Self.imageSequenceMaxTotalFrames else {
            throw ToolError("Resulting video is too long: \(imageURLs.count) images × \(framesPerImage) frames = \(totalFrames) frames (max \(Self.imageSequenceMaxTotalFrames)). Lower framesPerImage or split the sequence.")
        }

        let width = editor.timeline.width
        let height = editor.timeline.height

        guard let projectURL = editor.projectURL else {
            throw ToolError("No project is open; cannot create an image sequence.")
        }
        let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        } catch {
            throw ToolError("Failed to prepare media directory: \(error.localizedDescription)")
        }
        let destURL = mediaDir.appendingPathComponent("imgseq-\(UUID().uuidString.prefix(8)).mp4")

        // Encode off the main actor — only the model mutation below needs @MainActor.
        do {
            try await Task.detached(priority: .userInitiated) {
                try ImageSequenceEncoder.encode(
                    images: imageURLs, width: width, height: height,
                    fps: fps, framesPerImage: framesPerImage, to: destURL
                )
            }.value
        } catch {
            try? FileManager.default.removeItem(at: destURL)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw ToolError("Failed to encode image sequence: \(message)")
        }

        guard let asset = editor.addMediaAsset(from: destURL) else {
            try? FileManager.default.removeItem(at: destURL)
            throw ToolError("Encoded the sequence but failed to register it as a media asset.")
        }

        if let name = args.string("name") {
            asset.name = name
            if let idx = editor.mediaManifest.entries.firstIndex(where: { $0.id == asset.id }) {
                editor.mediaManifest.entries[idx].name = name
            }
        }
        if let folderId = try resolveFolderId(args, editor: editor) {
            editor.moveAssetsToFolder(assetIds: [asset.id], folderId: folderId)
        }

        let seconds = Double(totalFrames) / Double(fps)
        let base = String(
            format: "Assembled %d image(s) into video '%@' (id: %@, %d×%d, %d fps, %d frame(s)/image, %d frames ≈ %.2fs).",
            imageURLs.count, asset.name, asset.id, width, height, fps, framesPerImage, totalFrames, seconds
        )

        // Optionally drop the assembled clip straight onto the timeline, reusing add_clips so
        // track auto-creation and overlap handling stay identical to a normal placement.
        guard args.bool("addToTimeline") == true else {
            return .ok(base + " It's in the media library — place it with add_clips using durationFrames: \(totalFrames).")
        }

        let startFrame = max(0, args.int("startFrame") ?? 0)
        let trackIndex = args.int("trackIndex")
        var entry: [String: Any] = [
            "mediaRef": asset.id,
            "startFrame": startFrame,
            "durationFrames": totalFrames,
        ]
        if let trackIndex { entry["trackIndex"] = trackIndex }
        _ = try addClips(editor, ["entries": [entry]])

        let trackNote = trackIndex.map { " on track \($0)" } ?? " on a new track"
        return .ok(base + " Placed at frame \(startFrame)\(trackNote) for \(totalFrames) frames.")
    }

    private static func resolveImageURLs(directory: String?, paths: [String]) throws -> [URL] {
        if let directory {
            let dirURL = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
                throw ToolError("directory not found or not a directory: \(directory)")
            }
            let entries = try FileManager.default.contentsOfDirectory(
                at: dirURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            return entries
                .filter { imageSequenceExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }

        var urls: [URL] = []
        for p in paths {
            let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError("Image file not found: \(p)")
            }
            guard imageSequenceExtensions.contains(url.pathExtension.lowercased()) else {
                throw ToolError("Unsupported image type '.\(url.pathExtension)' for \(url.lastPathComponent). Supported: png, jpg, jpeg, tiff, heic.")
            }
            urls.append(url)
        }
        return urls
    }
}

/// Offline image-sequence → H.264 encoder. Each image is drawn once into a canvas-sized pixel
/// buffer (aspect-fit, letterboxed) and appended once per held frame, so the output duration is
/// exactly `images.count × framesPerImage / fps`. Runs synchronously on a background thread
/// (called from a detached task), so the `isReadyForMoreMediaData` wait loop is acceptable.
enum ImageSequenceEncoder {
    static func encode(
        images: [URL], width: Int, height: Int, fps: Int, framesPerImage: Int, to outputURL: URL
    ) throws {
        try? FileManager.default.removeItem(at: outputURL)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false

        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: bufferAttrs
        )

        guard writer.canAdd(input) else { throw ImageSequenceError.writerSetup }
        writer.add(input)
        guard writer.startWriting() else { throw ImageSequenceError.writerStart(writer.error) }
        writer.startSession(atSourceTime: .zero)

        let timescale = Int32(fps)
        var pts: Int64 = 0
        for url in images {
            let buffer = try makePixelBuffer(for: url, width: width, height: height, pool: adaptor.pixelBufferPool)
            for _ in 0..<framesPerImage {
                while !input.isReadyForMoreMediaData {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                if !adaptor.append(buffer, withPresentationTime: CMTime(value: pts, timescale: timescale)) {
                    throw ImageSequenceError.appendFailed(writer.error)
                }
                pts += 1
            }
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: pts, timescale: timescale))

        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()

        guard writer.status == .completed else {
            throw ImageSequenceError.finish(writer.error)
        }
    }

    private static func makePixelBuffer(
        for url: URL, width: Int, height: Int, pool: CVPixelBufferPool?
    ) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageSequenceError.imageLoad(url)
        }

        var pixelBuffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            let attrs: [String: Any] = [
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ]
            CVPixelBufferCreate(
                kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer
            )
        }
        guard let buffer = pixelBuffer else { throw ImageSequenceError.bufferAlloc }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ImageSequenceError.bufferAlloc }
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            throw ImageSequenceError.context
        }

        // Letterbox onto a black canvas, aspect preserved.
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let iw = CGFloat(cgImage.width), ih = CGFloat(cgImage.height)
        let cw = CGFloat(width), ch = CGFloat(height)
        guard iw > 0, ih > 0 else { throw ImageSequenceError.imageLoad(url) }
        let scale = min(cw / iw, ch / ih)
        let dw = iw * scale, dh = ih * scale
        ctx.draw(cgImage, in: CGRect(x: (cw - dw) / 2, y: (ch - dh) / 2, width: dw, height: dh))

        return buffer
    }
}

enum ImageSequenceError: LocalizedError {
    case writerSetup
    case writerStart(Error?)
    case appendFailed(Error?)
    case finish(Error?)
    case imageLoad(URL)
    case bufferAlloc
    case context

    var errorDescription: String? {
        switch self {
        case .writerSetup: return "could not configure the video writer"
        case .writerStart(let e): return "video writer failed to start (\(e?.localizedDescription ?? "unknown"))"
        case .appendFailed(let e): return "failed to append a frame (\(e?.localizedDescription ?? "unknown"))"
        case .finish(let e): return "video writer failed to finalize (\(e?.localizedDescription ?? "unknown"))"
        case .imageLoad(let url): return "could not read image \(url.lastPathComponent)"
        case .bufferAlloc: return "could not allocate a pixel buffer"
        case .context: return "could not create a drawing context"
        }
    }
}
