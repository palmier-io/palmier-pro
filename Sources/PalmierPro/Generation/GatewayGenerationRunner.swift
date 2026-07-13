import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One gateway image job: which protoBanana op, which alias, and its inputs.
/// References are local file URLs — the gateway takes media inline (multipart /
/// data URLs), never via an upload step (GATEWAY_CONTRACT.md).
struct GatewayImageJob: Sendable {
    enum Op: Sendable, Equatable {
        case generate       // POST /images/generations
        case edit           // POST /images/edits (+ op-specific fields)
        case compose        // POST /chat/completions on the chat alias
    }

    let op: Op
    let model: String
    let prompt: String
    var size: String?               // "WxH"; generate only
    var n: Int = 1
    var referenceURLs: [URL] = []   // edit: [image]; compose: 2–3 images
    var personURL: URL?             // identity edit two-ref
    var fields: [String: String] = [:]   // grounding, grounding_px, margins…
    var seed: Int?
    var negativePrompt: String?
}

/// One gateway video job (async bridge shape). The optional reference is the
/// first frame (image-to-video); everything else the hosted path offers
/// (end frame, multi-ref, source video) is unmappable and rejected upstream.
struct GatewayVideoJob: Sendable {
    let model: String
    let prompt: String
    let seconds: Int
    var size: String?
    var inputReferenceURL: URL?   // image → i2v first frame; video → extend guide
    var lastFrameURL: URL?        // image; with an image input_reference → first-last-frame
}

/// ACE-Step audio (GATEWAY_CONTRACT.md audio section). Sync b64 — no polling.
/// `.generate` posts /audio/generations; the edit ops post /audio/edits with the
/// source clip and op-specific `fields` (start_s/end_s/variance/direction/edit_strength).
struct GatewayAudioJob: Sendable {
    enum Op: String, Sendable { case generate, extend, repaint, edit }
    var op: Op = .generate
    let model: String
    let prompt: String
    var lyrics: String?
    var instrumental: Bool = false
    var seconds: Int?
    var n: Int = 1
    var seed: Int?
    var negativePrompt: String?
    var format: String = "mp3"
    var sourceAudioURL: URL?
    var fields: [String: String] = [:]
}

/// Pure routing: how many references → which op. nil = unmappable.
enum GatewayImageRouting {
    static func op(forReferenceCount count: Int) -> GatewayImageJob.Op? {
        switch count {
        case 0: .generate
        case 1: .edit
        case 2, 3: .compose
        default: nil
        }
    }
}

/// Executes a GatewayImageJob against the OpenAI-compatible client: downscales
/// references under the gateway's form-part cap, applies the seed policy, and
/// dispatches per op. Stateless — placeholder lifecycle stays in GenerationService.
enum GatewayGenerationRunner {
    /// The gateway rejects multipart parts over 1 MB (GATEWAY_CONTRACT.md).
    static let maxPartBytes = 1_000_000

    static func execute(_ job: GatewayImageJob, client: OpenAICompatGenerationClient) async throws -> [URL] {
        // Identical resubmission hits ComfyUI's execution cache and returns empty
        // outputs (protoBanana#34) — default to a fresh seed for single outputs;
        // n>1 lets the server vary seeds itself.
        let seed = job.seed ?? (job.n == 1 ? Int.random(in: 0..<Int(Int32.max)) : nil)

        switch job.op {
        case .generate:
            return try await client.generateImages(
                model: job.model, prompt: job.prompt, n: job.n, size: job.size,
                seed: seed, negativePrompt: job.negativePrompt
            )
        case .edit:
            guard let imageURL = job.referenceURLs.first else {
                throw OpenAICompatGenerationError.api("edit op needs a reference image")
            }
            var fields = job.fields
            if let seed { fields["seed"] = String(seed) }
            if let negative = job.negativePrompt { fields["negative_prompt"] = negative }
            if let personURL = job.personURL {
                let personData = try preparedImageData(from: personURL)
                fields["person_image"] = "data:image/png;base64," + personData.base64EncodedString()
            }
            return try await client.editImage(
                model: job.model, prompt: job.prompt,
                image: try preparedImageData(from: imageURL),
                fields: fields
            )
        case .compose:
            guard (2...3).contains(job.referenceURLs.count) else {
                throw OpenAICompatGenerationError.api("compose takes 2–3 reference images (got \(job.referenceURLs.count))")
            }
            let images = try job.referenceURLs.map { try preparedImageData(from: $0) }
            return try await client.chatCompose(model: job.model, prompt: job.prompt, images: images)
        }
    }

    /// Reads an image and re-encodes under the gateway part cap. PNG passes
    /// through when already small enough (preserves alpha); otherwise scale +
    /// JPEG-encode until it fits.
    static func preparedImageData(from url: URL, limit: Int = maxPartBytes) throws -> Data {
        let raw = try Data(contentsOf: url)
        if raw.count <= limit { return raw }
        return try downscaled(raw, limit: limit)
    }

    static func downscaled(_ data: Data, limit: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              var image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw OpenAICompatGenerationError.api("Reference is not a decodable image")
        }
        var quality = 0.85
        for _ in 0..<6 {
            let encoded = try jpegData(image, quality: quality)
            if encoded.count <= limit { return encoded }
            // Shrink area toward the byte budget; JPEG size tracks area roughly linearly.
            let scale = (Double(limit) / Double(encoded.count)).squareRoot() * 0.9
            let w = max(64, Int(Double(image.width) * scale))
            let h = max(64, Int(Double(image.height) * scale))
            guard let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw OpenAICompatGenerationError.api("Could not downscale reference image") }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaledImage = ctx.makeImage() else {
                throw OpenAICompatGenerationError.api("Could not downscale reference image")
            }
            image = scaledImage
            quality = max(0.6, quality - 0.05)
        }
        let final = try jpegData(image, quality: 0.6)
        guard final.count <= limit else {
            throw OpenAICompatGenerationError.api("Reference image could not be reduced under \(limit / 1000) KB")
        }
        return final
    }

    private static func jpegData(_ image: CGImage, quality: Double) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw OpenAICompatGenerationError.api("Could not encode reference image")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw OpenAICompatGenerationError.api("Could not encode reference image")
        }
        return out as Data
    }

    // MARK: - Video

    // Overridable so tests poll in milliseconds.
    nonisolated(unsafe) static var videoPollInterval: Duration = .seconds(10)
    nonisolated(unsafe) static var videoTimeout: Duration = .seconds(900)

    /// Submit and poll to completion; returns the downloaded mp4 as a temp file.
    /// onCreated fires with the job id as soon as the bridge assigns it (persisted
    /// for restart-resume).
    static func executeVideo(
        _ job: GatewayVideoJob,
        client: OpenAICompatGenerationClient,
        onCreated: @MainActor (String) -> Void
    ) async throws -> URL {
        var inputReference: OpenAICompatGenerationClient.VideoInput?
        if let url = job.inputReferenceURL {
            // A video guide is sent as-is (extend); an image is downscaled to the part cap.
            inputReference = isVideoReference(url)
                ? .video(try Data(contentsOf: url))
                : .image(try preparedImageData(from: url))
        }
        var lastFrame: Data?
        if let url = job.lastFrameURL {
            guard let ref = job.inputReferenceURL else {
                throw OpenAICompatGenerationError.api("first-last-frame needs a start frame alongside the last frame")
            }
            guard !isVideoReference(ref) else {
                throw OpenAICompatGenerationError.api("first-last-frame takes two images — the start frame can't be a video")
            }
            lastFrame = try preparedImageData(from: url)
        }
        let id = try await client.createVideo(
            model: job.model, prompt: job.prompt, seconds: job.seconds,
            size: job.size, inputReference: inputReference, lastFrame: lastFrame
        )
        await onCreated(id)
        return try await pollVideo(id: id, client: client)
    }

    /// ACE-Step audio — sync bytes back, no job/poll (unlike video). `.generate`
    /// hits /audio/generations; edit ops upload the source clip to /audio/edits.
    static func executeAudio(_ job: GatewayAudioJob, client: OpenAICompatGenerationClient) async throws -> [URL] {
        if job.op == .generate {
            return try await client.generateMusic(
                model: job.model, prompt: job.prompt, lyrics: job.lyrics,
                instrumental: job.instrumental, seconds: job.seconds, n: job.n,
                seed: job.seed, negativePrompt: job.negativePrompt, format: job.format
            )
        }
        guard let src = job.sourceAudioURL else {
            throw OpenAICompatGenerationError.api("\(job.op.rawValue) needs a source audio clip")
        }
        var fields = job.fields
        if !job.prompt.isEmpty { fields["prompt"] = job.prompt }
        if let lyrics = job.lyrics, !lyrics.isEmpty { fields["lyrics"] = lyrics }
        if let seconds = job.seconds { fields["seconds"] = String(seconds) }
        if let seed = job.seed { fields["seed"] = String(seed) }
        fields["format"] = job.format
        return try await client.editAudio(
            model: job.model, audio: try Data(contentsOf: src),
            filename: src.lastPathComponent, contentType: audioContentType(src), fields: fields
        )
    }

    static let audioContentTypes: [String: String] = [
        "mp3": "audio/mpeg", "wav": "audio/wav", "flac": "audio/flac",
        "ogg": "audio/ogg", "opus": "audio/opus", "m4a": "audio/mp4", "aac": "audio/aac",
    ]

    static func audioContentType(_ url: URL) -> String {
        audioContentTypes[url.pathExtension.lowercased()] ?? "audio/mpeg"
    }

    /// Container extensions the bridge treats as an extend guide rather than a still.
    static let videoReferenceExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "avi", "mkv"]

    static func isVideoReference(_ url: URL) -> Bool {
        videoReferenceExtensions.contains(url.pathExtension.lowercased())
    }

    /// Poll loop — also the restart-resume entry (status GETs are stateless).
    static func pollVideo(id: String, client: OpenAICompatGenerationClient) async throws -> URL {
        let deadline = ContinuousClock.now + videoTimeout
        var lastLoggedProgress = -1
        while ContinuousClock.now < deadline {
            let status = try await client.videoStatus(id: id)
            switch status.status {
            case "completed":
                return try await client.videoContent(id: id)
            case "failed":
                throw OpenAICompatGenerationError.api(status.errorMessage ?? "Video generation failed")
            default:
                if let progress = status.progress, progress != lastLoggedProgress {
                    lastLoggedProgress = progress
                    Log.generation.notice("gateway video \(id) \(status.status) \(progress)%")
                }
                try await Task.sleep(for: videoPollInterval)
            }
        }
        throw OpenAICompatGenerationError.api("Video generation timed out after \(Int(videoTimeout.components.seconds))s")
    }

    /// LTX-native buckets per aspect ratio for the video path.
    static let videoAspectSizes: [String: String] = [
        "16:9": "1216x704", "9:16": "704x1216", "1:1": "1024x1024",
    ]

    static func videoSize(resolution: String?, aspectRatio: String?) -> String? {
        if let explicit = sizeParameter(resolution: resolution) { return explicit }
        guard let aspectRatio else { return nil }
        return videoAspectSizes[aspectRatio.trimmingCharacters(in: .whitespaces)]
    }

    /// Qwen-Image native buckets per aspect ratio (protoBanana snaps arbitrary
    /// sizes, but native buckets skip the snap).
    static let aspectSizes: [String: String] = [
        "1:1": "1328x1328", "16:9": "1664x928", "9:16": "928x1664",
        "4:3": "1472x1140", "3:4": "1140x1472",
    ]

    /// Explicit WxH wins; else map the aspect ratio; else let the model pick.
    static func size(resolution: String?, aspectRatio: String?) -> String? {
        if let explicit = sizeParameter(resolution: resolution) { return explicit }
        guard let aspectRatio else { return nil }
        return aspectSizes[aspectRatio.trimmingCharacters(in: .whitespaces)]
    }

    /// "WxH" passthrough for /images/generations; nil lets the model pick.
    static func sizeParameter(resolution: String?) -> String? {
        guard let r = resolution?.trimmingCharacters(in: .whitespacesAndNewlines),
              ImageModelConfig.parseWxH(r) != nil else { return nil }
        return r
    }
}
