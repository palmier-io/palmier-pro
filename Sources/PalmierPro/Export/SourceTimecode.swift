import AVFoundation
import Foundation

/// A source file's start timecode: frame number in the timecode track's own `quanta` rate, plus its
/// drop-frame flag. Many cameras embed a running timecode, so footage often starts non-zero.
struct SourceTimecode: Equatable {
    let frame: Int
    let quanta: Int
    let dropFrame: Bool

    /// Start timecode expressed in `fps`-frame units (for a progressive source, `quanta` == `fps`).
    func frames(atFPS fps: Int) -> Int {
        guard quanta > 0 else { return 0 }
        return Int((Double(frame) / Double(quanta) * Double(fps)).rounded())
    }
}

enum SourceTimecodeReader {
    static func cache(mediaRefs: Set<String>, urls: [String: URL]) async -> [String: SourceTimecode] {
        await withTaskGroup(of: (String, SourceTimecode?).self) { group in
            for mediaRef in mediaRefs {
                guard let url = urls[mediaRef] else { continue }
                group.addTask { (mediaRef, await read(url: url)) }
            }
            var cache: [String: SourceTimecode] = [:]
            for await (mediaRef, timecode) in group {
                if let timecode { cache[mediaRef] = timecode }
            }
            return cache
        }
    }

    static func read(url: URL) async -> SourceTimecode? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let format = try? await track.load(.formatDescriptions).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(format))
        let dropFrame = CMTimeCodeFormatDescriptionGetTimeCodeFlags(format) & UInt32(kCMTimeCodeFlag_DropFrame) != 0
        guard quanta > 0 else { return nil }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var be: UInt32 = 0
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &be) == kCMBlockBufferNoErr
            else { return nil }
            return SourceTimecode(frame: Int(UInt32(bigEndian: be)), quanta: quanta, dropFrame: dropFrame)
        }
        return nil
    }
}
