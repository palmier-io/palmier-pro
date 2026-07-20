import AVFoundation
import Foundation

/// A clip's start timecode: frame number at `quanta` rate with drop-frame flag.
struct SourceTimecode: Equatable {
    /// Exact seconds per TC frame (1001/30000 for NTSC).
    struct Tick: Equatable {
        let num: Int
        let den: Int
    }

    let frame: Int
    let quanta: Int
    let dropFrame: Bool
    /// nil falls back to 1/quanta.
    var tick: Tick? = nil

    /// Start timecode expressed in `fps`-frame units (for a progressive source, `quanta` == `fps`).
    func frames(atFPS fps: Int) -> Int {
        guard quanta > 0 else { return 0 }
        return Int((Double(frame) / Double(quanta) * Double(fps)).rounded())
    }

    var seconds: Double {
        let s = rationalSeconds
        return Double(s.num) / Double(s.den)
    }

    /// Rational seconds (with exact NTSC tick if needed) to prevent drift.
    var rationalSeconds: (num: Int, den: Int) {
        guard quanta > 0 else { return (0, 1) }
        if let tick, tick.num > 0, tick.den > 0 { return (frame * tick.num, tick.den) }
        return (frame, quanta)
    }
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
        if let tc = await tmcdTimecode(url: url) { return tc }
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return rtmdTimecode(data) ?? bwfTimecode(data)
    }

    private static func tmcdTimecode(url: URL) async -> SourceTimecode? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let format = try? await track.load(.formatDescriptions).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let quanta = Int(CMTimeCodeFormatDescriptionGetFrameQuanta(format))
        let dropFrame = CMTimeCodeFormatDescriptionGetTimeCodeFlags(format) & UInt32(kCMTimeCodeFlag_DropFrame) != 0
        guard quanta > 0 else { return nil }
        let duration = CMTimeCodeFormatDescriptionGetFrameDuration(format)
        let tick: SourceTimecode.Tick? = duration.isNumeric && duration.seconds > 0
            ? .init(num: Int(duration.value), den: Int(duration.timescale)) : nil

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            var be: UInt32 = 0
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: 4, destination: &be) == kCMBlockBufferNoErr
            else { return nil }
            return SourceTimecode(frame: Int(UInt32(bigEndian: be)), quanta: quanta, dropFrame: dropFrame, tick: tick)
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

    // MARK: - Sony rtmd (RDD 18 metadata track)

    /// Sony XAVC stores time-of-day timecode in an `rtmd` track that AVFoundation ignores.
    /// The first sample's bytes 13–17 are hh/mm/ss/dropFlag/ff in binary.
    static func rtmdTimecode(_ data: Data) -> SourceTimecode? {
        guard let moov = mp4Children(data, in: 0..<data.count).first(where: { $0.type == "moov" })?.body
        else { return nil }
        for trak in mp4Children(data, in: moov) where trak.type == "trak" {
            guard let mdia = mp4Child("mdia", data, in: trak.body),
                  let minf = mp4Child("minf", data, in: mdia),
                  let stbl = mp4Child("stbl", data, in: minf),
                  let stsd = mp4Child("stsd", data, in: stbl),
                  fourcc(data, stsd.lowerBound + 12) == "rtmd",
                  let mdhd = mp4Child("mdhd", data, in: mdia),
                  let stts = mp4Child("stts", data, in: stbl),
                  let version = byte(data, mdhd.lowerBound),
                  let timescale = be(data, mdhd.lowerBound + (version == 1 ? 20 : 12), 4),
                  let delta = be(data, stts.lowerBound + 12, 4), timescale > 0, delta > 0
            else { continue }

            var sample: Int?
            if let stco = mp4Child("stco", data, in: stbl), let n = be(data, stco.lowerBound + 4, 4), n > 0 {
                sample = be(data, stco.lowerBound + 8, 4).map(Int.init)
            } else if let co64 = mp4Child("co64", data, in: stbl), let n = be(data, co64.lowerBound + 4, 4), n > 0 {
                sample = be(data, co64.lowerBound + 8, 8).map(Int.init)
            }
            guard let offset = sample,
                  let hh = byte(data, offset + 13), let mm = byte(data, offset + 14),
                  let ss = byte(data, offset + 15), let drop = byte(data, offset + 16),
                  let ff = byte(data, offset + 17) else { continue }

            let quanta = Int((Double(timescale) / Double(delta)).rounded())
            guard quanta > 0, hh < 24, mm < 60, ss < 60, Int(ff) < quanta else { continue }
            // NTSC-rate rtmd is drop-frame regardless of the flag byte: Sony time-of-day TC at
            // 29.97/59.94 is DF, and Resolve conforms on that reading (NDF lands ~1s/15min off).
            let ntsc = delta == 1001 && timescale % 30000 == 0
            let dropFrame = drop != 0 || (ntsc && quanta % 30 == 0)
            var frame = (Int(hh) * 3600 + Int(mm) * 60 + Int(ss)) * quanta + Int(ff)
            if dropFrame {
                // Display TC → raw frame count: remove the frame numbers DF skips.
                let d = Int((Double(quanta) * 0.066666).rounded())
                let mins = Int(hh) * 60 + Int(mm)
                frame -= d * (mins - mins / 10)
            }
            return SourceTimecode(frame: frame, quanta: quanta, dropFrame: dropFrame,
                                  tick: .init(num: Int(delta), den: Int(timescale)))
        }
        return nil
    }

    // MARK: - BWF (bext TimeReference)

    /// BWF start timecode is `bext.TimeReference`: samples since midnight. Returned sample-based
    /// (`quanta` = sample rate); `seconds`/`frames(atFPS:)` are exact, XMEML rescales for display.
    static func bwfTimecode(_ data: Data) -> SourceTimecode? {
        let magic = fourcc(data, 0)
        guard magic == "RIFF" || magic == "RF64", fourcc(data, 8) == "WAVE" else { return nil }
        var pos = 12
        var sampleRate = 0
        var timeReference: UInt64?
        while pos + 8 <= data.count {
            guard let type = fourcc(data, pos), let size32 = le(data, pos + 4, 4),
                  size32 != 0xFFFF_FFFF else { break }  // RF64 jumbo data chunk; fmt/bext precede it
            if type == "fmt " { sampleRate = Int(le(data, pos + 12, 4) ?? 0) }
            if type == "bext", size32 >= 346 { timeReference = le(data, pos + 8 + 338, 8) }
            if sampleRate > 0, timeReference != nil { break }
            pos += 8 + Int(size32) + (Int(size32) & 1)
        }
        guard let reference = timeReference, reference > 0, sampleRate > 0, let frame = Int(exactly: reference)
        else { return nil }
        return SourceTimecode(frame: frame, quanta: sampleRate, dropFrame: false)
    }

    // MARK: - Byte helpers

    private static func byte(_ data: Data, _ offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[data.startIndex + offset]
    }

    private static func be(_ data: Data, _ offset: Int, _ count: Int) -> UInt64? {
        guard offset >= 0, offset + count <= data.count else { return nil }
        return (0..<count).reduce(0) { $0 << 8 | UInt64(data[data.startIndex + offset + $1]) }
    }

    private static func le(_ data: Data, _ offset: Int, _ count: Int) -> UInt64? {
        guard offset >= 0, offset + count <= data.count else { return nil }
        return (0..<count).reversed().reduce(0) { $0 << 8 | UInt64(data[data.startIndex + offset + $1]) }
    }

    private static func fourcc(_ data: Data, _ offset: Int) -> String? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        let start = data.startIndex + offset
        return String(bytes: data[start..<start + 4], encoding: .ascii)
    }

    private static func mp4Children(_ data: Data, in range: Range<Int>) -> [(type: String, body: Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        var pos = range.lowerBound
        while pos + 8 <= range.upperBound {
            guard let size32 = be(data, pos, 4), let type = fourcc(data, pos + 4) else { break }
            var body = pos + 8
            var size = Int(size32)
            if size32 == 1 {
                guard let large = be(data, pos + 8, 8), let s = Int(exactly: large) else { break }
                size = s
                body = pos + 16
            } else if size32 == 0 {
                size = range.upperBound - pos
            }
            guard size >= body - pos, pos + size <= range.upperBound else { break }
            out.append((type, body..<(pos + size)))
            pos += size
        }
        return out
    }

    private static func mp4Child(_ type: String, _ data: Data, in range: Range<Int>) -> Range<Int>? {
        mp4Children(data, in: range).first { $0.type == type }?.body
    }
}
