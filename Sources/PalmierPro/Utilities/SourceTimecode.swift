import AVFoundation
import Foundation

/// A clip's start timecode: frame number at `quanta` rate with drop-frame flag.
struct SourceTimecode: Equatable {
    let frame: Int
    let quanta: Int
    let dropFrame: Bool
    /// Exact seconds per TC frame (1001/30000 for NTSC); nil falls back to 1/quanta.
    var frameDuration: Double? = nil

    /// Start timecode expressed in `fps`-frame units (for a progressive source, `quanta` == `fps`).
    func frames(atFPS fps: Int) -> Int {
        guard quanta > 0 else { return 0 }
        return Int((Double(frame) / Double(quanta) * Double(fps)).rounded())
    }

    var seconds: Double { Double(frame) * (frameDuration ?? (quanta > 0 ? 1 / Double(quanta) : 0)) }
}

/// Per-file sync signals: embedded SMPTE timecode and/or recording-start capture date.
struct SourceTiming: Sendable, Equatable {
    var timecode: SourceTimecode?
    var captureDate: Date?
}

enum SourceTimingReader {
    static func cache(mediaRefs: Set<String>, urls: [String: URL]) async -> [String: SourceTiming] {
        await withTaskGroup(of: (String, SourceTiming).self) { group in
            for mediaRef in mediaRefs {
                guard let url = urls[mediaRef] else { continue }
                group.addTask { (mediaRef, await read(url: url)) }
            }
            var cache: [String: SourceTiming] = [:]
            for await (mediaRef, timing) in group where timing != SourceTiming() {
                cache[mediaRef] = timing
            }
            return cache
        }
    }

    static func timecodes(mediaRefs: Set<String>, urls: [String: URL]) async -> [String: SourceTimecode] {
        await cache(mediaRefs: mediaRefs, urls: urls).compactMapValues(\.timecode)
    }

    static func read(url: URL) async -> SourceTiming {
        async let timecode = timecode(url: url)
        async let captureDate = captureDate(url: url)
        return await SourceTiming(timecode: timecode, captureDate: captureDate)
    }

    private static func timecode(url: URL) async -> SourceTimecode? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let format = try? await track.load(.formatDescriptions).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(format))
        let dropFrame = CMTimeCodeFormatDescriptionGetTimeCodeFlags(format) & UInt32(kCMTimeCodeFlag_DropFrame) != 0
        guard quanta > 0 else { return nil }
        let tick = CMTimeCodeFormatDescriptionGetFrameDuration(format)
        let frameDuration = tick.isNumeric && tick.seconds > 0 ? tick.seconds : nil

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var be: UInt32 = 0
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &be) == kCMBlockBufferNoErr
            else { return nil }
            return SourceTimecode(frame: Int(UInt32(bigEndian: be)), quanta: quanta, dropFrame: dropFrame, frameDuration: frameDuration)
        }
        return nil
    }

    /// QuickTime recording start; file creation time stamps finalization, not capture.
    private static func captureDate(url: URL) async -> Date? {
        guard let items = try? await AVURLAsset(url: url).load(.metadata),
              let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .quickTimeMetadataCreationDate).first
        else { return nil }
        if let date = try? await item.load(.dateValue) { return date }
        if let string = try? await item.load(.stringValue) { return parseQuickTimeDate(string) }
        return nil
    }

    static func parseQuickTimeDate(_ string: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: string) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZ"
        return formatter.date(from: string)
    }
}
