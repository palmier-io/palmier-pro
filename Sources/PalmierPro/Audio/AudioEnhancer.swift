import AVFoundation
import Accelerate
import SpeechEnhancement

enum AudioEnhancer {
    static let cache = DiskCache(named: "EnhancedAudio")

    enum EnhanceError: LocalizedError {
        case noAudioTrack
        case writeFailed

        var errorDescription: String? {
            switch self {
            case .noAudioTrack: "Source has no audio track"
            case .writeFailed: "Could not write enhanced audio"
            }
        }
    }

    private static let modelBox = ModelBox()

    private actor ModelBox {
        private var enhancer: SpeechEnhancer?

        func enhance(audio: [Float], sampleRate: Int) async throws -> [Float] {
            if enhancer == nil { enhancer = try await SpeechEnhancer.fromPretrained() }
            return try enhancer!.enhanceChunked(audio: audio, sampleRate: sampleRate)
        }
    }

    private static var sampleRate: Double { Double(SpeechEnhancer.sampleRate) }

    static func enhancedAudio(for sourceURL: URL, mediaRef: String, amount: Double) async throws -> URL {
        if let cached = cachedURL(for: sourceURL, mediaRef: mediaRef, amount: amount) { return cached }
        let wet = try await wetChannels(for: sourceURL, mediaRef: mediaRef)
        let dry = try await readChannels(from: sourceURL, channelCount: wet.count)
        let w = Float(min(1, max(0, amount)))
        let mixed = zip(dry, wet).map { dry, wet in
            let n = min(dry.count, wet.count)
            return vDSP.add(multiplication: (wet[0..<n], w), multiplication: (dry[0..<n], 1 - w))
        }
        let outputURL = mixedOutputURL(for: sourceURL, mediaRef: mediaRef, amount: amount)
        try write(channels: mixed, to: outputURL)
        return outputURL
    }

    static func cachedURL(for sourceURL: URL, mediaRef: String, amount: Double) -> URL? {
        if percent(amount) == 0 { return sourceURL }
        let url = mixedOutputURL(for: sourceURL, mediaRef: mediaRef, amount: amount)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Cache paths

    private static func percent(_ amount: Double) -> Int {
        Int((min(1, max(0, amount)) * 100).rounded())
    }

    private static func mixedOutputURL(for sourceURL: URL, mediaRef: String, amount: Double) -> URL {
        cache.directory.appendingPathComponent("\(mediaRef)_\(cacheTag(for: sourceURL))_\(percent(amount))_denoised.caf")
    }

    private static func cacheTag(for url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? Int) ?? 0
        let modified = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)_\(Int(modified))"
    }

    // MARK: - Reading

    private static func readChannels(from url: URL, channelCount: Int? = nil) async throws -> [[Float]] {
        let count: Int
        if let channelCount {
            count = channelCount
        } else {
            let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first
            let desc = try await track?.load(.formatDescriptions).first
            let channels = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
            count = min(2, max(1, Int(channels)))
        }
        var channels = [[Float]](repeating: [], count: count)
        try await AudioTrackReader.read(
            from: url,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: count,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: true,
            ]
        ) { buffer in
            guard let data = buffer.floatChannelData else { return }
            for ch in 0..<count {
                channels[ch].append(contentsOf: UnsafeBufferPointer(start: data[ch], count: Int(buffer.frameLength)))
            }
        }
        return channels
    }

    private static func wetChannels(for sourceURL: URL, mediaRef: String) async throws -> [[Float]] {
        let wetURL = cache.directory.appendingPathComponent("\(mediaRef)_\(cacheTag(for: sourceURL))_wet.caf")
        if FileManager.default.fileExists(atPath: wetURL.path) {
            let cached = try await readChannels(from: wetURL)
            if cached.contains(where: { !$0.isEmpty }) { return cached }
        }

        let dryChannels = try await readChannels(from: sourceURL)
        guard dryChannels.contains(where: { !$0.isEmpty }) else { throw EnhanceError.noAudioTrack }

        var wet: [[Float]] = []
        for dry in dryChannels {
            wet.append(dry.isEmpty ? dry : try await modelBox.enhance(audio: dry, sampleRate: SpeechEnhancer.sampleRate))
        }
        try write(channels: wet, to: wetURL)
        return wet
    }

    // MARK: - Writing

    private static func write(channels: [[Float]], to outputURL: URL) throws {
        guard let frameCount = channels.first?.count, frameCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { throw EnhanceError.writeFailed }
        outBuffer.frameLength = AVAudioFrameCount(frameCount)
        for ch in channels.indices {
            channels[ch].withUnsafeBufferPointer { src in
                outBuffer.floatChannelData?[ch].update(from: src.baseAddress!, count: channels[ch].count)
            }
        }

        let fm = FileManager.default
        try? fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tempURL = outputURL.deletingLastPathComponent().appendingPathComponent(".writing-\(UUID().uuidString).caf")
        defer { try? fm.removeItem(at: tempURL) }
        let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        try file.write(from: outBuffer)

        guard !fm.fileExists(atPath: outputURL.path) else { return }
        do {
            try fm.moveItem(at: tempURL, to: outputURL)
        } catch {
            guard fm.fileExists(atPath: outputURL.path) else { throw error }
        }
    }
}
