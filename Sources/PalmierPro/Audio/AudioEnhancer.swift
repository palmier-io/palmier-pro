import AVFoundation
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

    static func denoisedAudio(for sourceURL: URL, mediaRef: String) async throws -> URL {
        let outputURL = denoisedURL(for: sourceURL, mediaRef: mediaRef)
        if FileManager.default.fileExists(atPath: outputURL.path) { return outputURL }
        var dry = try await readChannels(from: sourceURL)
        guard dry.contains(where: { !$0.isEmpty }) else { throw EnhanceError.noAudioTrack }
        var wet: [[Float]] = []
        for ch in dry.indices {
            wet.append(try await modelBox.enhance(audio: dry[ch], sampleRate: SpeechEnhancer.sampleRate))
            dry[ch] = []
        }
        removeStaleCaches(for: mediaRef, keeping: outputURL)
        try write(channels: wet, to: outputURL)
        return outputURL
    }

    static func cachedDenoisedURL(for sourceURL: URL, mediaRef: String) -> URL? {
        let url = denoisedURL(for: sourceURL, mediaRef: mediaRef)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func denoisedURL(for sourceURL: URL, mediaRef: String) -> URL {
        cache.directory.appendingPathComponent("\(mediaRef)_\(DiskCache.sizeMtimeTag(for: sourceURL))_wet.caf")
    }

    private static func removeStaleCaches(for mediaRef: String, keeping keep: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: cache.directory, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("\(mediaRef)_") && entry.lastPathComponent != keep.lastPathComponent {
            try? fm.removeItem(at: entry)
        }
    }

    // MARK: - Reading

    private static func readChannels(from url: URL) async throws -> [[Float]] {
        let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .audio).first
        let desc = try await track?.load(.formatDescriptions).first
        let sourceChannels = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame } ?? 1
        let count = min(2, max(1, Int(sourceChannels)))
        var channels = [[Float]](repeating: [], count: count)
        try await AudioTrackReader.read(
            from: url,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: count,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
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

    // MARK: - Writing

    private static func write(channels: [[Float]], to outputURL: URL) throws {
        guard let frameCount = channels.first?.count, frameCount > 0,
              channels.allSatisfy({ $0.count == frameCount }),
              let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels.count)),
              let outBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else { throw EnhanceError.writeFailed }
        outBuffer.frameLength = AVAudioFrameCount(frameCount)
        for ch in channels.indices {
            channels[ch].withUnsafeBufferPointer { src in
                outBuffer.floatChannelData?[ch].update(from: src.baseAddress!, count: frameCount)
            }
        }

        let tempURL = outputURL.deletingLastPathComponent().appendingPathComponent(".writing-\(UUID().uuidString).caf")
        try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
        try file.write(from: outBuffer)
        try FileIO.moveReplacingDestination(from: tempURL, to: outputURL)
    }
}
