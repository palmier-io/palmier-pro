import Foundation
import Testing
@testable import PalmierPro

/// PAL-166: Sony XAVC keeps timecode in an `rtmd` metadata track and BWF WAV in `bext.TimeReference`;
/// AVFoundation surfaces neither, so exports wrote start="0s" and Resolve refused to conform.
/// Fixtures are synthesized byte-for-byte from the layouts verified against real camera files
/// (a7S III 59.94p, RX100 VII 29.97p) and ffmpeg-authored BWF/RF64 WAVs.
@Suite("SourceTimingReader containers")
struct SourceTimecodeReaderTests {

    // MARK: - MP4 / rtmd

    private func box(_ type: String, _ body: Data) -> Data {
        var out = Data()
        var size = UInt32(8 + body.count).bigEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        out.append(type.data(using: .ascii)!)
        out.append(body)
        return out
    }

    private func u32(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return withUnsafeBytes(of: &be) { Data($0) }
    }

    /// Minimal MP4: moov(trak(mdia(mdhd + minf(stbl(stsd rtmd, stts, stco))))) + mdat with one
    /// rtmd sample whose bytes 13–17 are hh mm ss drop ff.
    private func rtmdFile(timescale: UInt32, delta: UInt32,
                          hh: UInt8, mm: UInt8, ss: UInt8, drop: UInt8, ff: UInt8) -> Data {
        var mdhd = Data([0, 0, 0, 0])                    // version 0 + flags
        mdhd += u32(0) + u32(0)                          // creation, modification
        mdhd += u32(timescale) + u32(0)                  // timescale, duration
        mdhd += Data([0, 0, 0, 0])

        let stsd = box("stsd", u32(0) + u32(1) + box("rtmd", Data(count: 8)))
        let stts = box("stts", u32(0) + u32(1) + u32(1) + u32(delta))

        var sample = Data(count: 13)
        sample += Data([hh, mm, ss, drop, ff])
        // stco chunk offset is absolute within the file; moov precedes mdat here.
        let stblSoFar = stsd + stts
        let fixedPrefix = 8       // moov hdr
            + 8                   // trak hdr
            + 8                   // mdia hdr
            + 8 + mdhd.count      // mdhd
            + 8                   // minf hdr
            + 8                   // stbl hdr
            + stblSoFar.count
            + 8 + 12              // stco box
            + 8                   // mdat hdr
        let stco = box("stco", u32(0) + u32(1) + u32(UInt32(fixedPrefix)))
        let stbl = box("stbl", stsd + stts + stco)
        let moov = box("moov", box("trak", box("mdia", box("mdhd", mdhd) + box("minf", stbl))))
        return moov + box("mdat", sample)
    }

    @Test func ntscRtmdIsDropFrameDespiteClearFlag() {
        // The a7S III layout: 59.94p track, flag byte 0, display 00:14:44:00. Sony time-of-day TC
        // at NTSC rates is DF and Resolve conforms on that reading; honoring the flag byte declared
        // an NDF origin ~0.9s off and Resolve dropped the media as out of range.
        let data = rtmdFile(timescale: 60000, delta: 1001, hh: 0, mm: 14, ss: 44, drop: 0, ff: 0)
        let tc = SourceTimingReader.rtmdTimecode(data)
        let raw = (14 * 60 + 44) * 60 - 4 * (14 - 1)   // 4 dropped per non-tenth minute @ 60
        #expect(tc == SourceTimecode(frame: raw, quanta: 60, dropFrame: true,
                                     tick: .init(num: 1001, den: 60000)))
    }

    @Test func integerRateRtmdHonorsClearDropFlag() {
        // A true 60p (non-NTSC) track stays NDF when the flag byte is clear.
        let data = rtmdFile(timescale: 60000, delta: 1000, hh: 1, mm: 2, ss: 3, drop: 0, ff: 4)
        let tc = SourceTimingReader.rtmdTimecode(data)
        #expect(tc == SourceTimecode(frame: (3600 + 120 + 3) * 60 + 4, quanta: 60, dropFrame: false,
                                     tick: .init(num: 1000, den: 60000)))
    }

    @Test func rtmdDropFrameConvertsDisplayToRawFrames() {
        // 14:34:12;58 @ 59.94 DF (the reporter's Sony time-of-day TC). Display TC skips 4 frame
        // numbers per non-tenth minute, so the raw count is lower than hh*3600... arithmetic.
        let data = rtmdFile(timescale: 60000, delta: 1001, hh: 14, mm: 34, ss: 12, drop: 1, ff: 58)
        let tc = SourceTimingReader.rtmdTimecode(data)
        let unwrapped = try! #require(tc)
        #expect(unwrapped.quanta == 60)
        #expect(unwrapped.dropFrame)
        // Round-trips through the DF formatter back to the display value.
        #expect(XMLExporter.formatTimecode(frame: unwrapped.frame, fps: 60, dropFrame: true) == "14;34;12;58")
    }

    @Test func rtmdRejectsInvalidFields() {
        // A frame count ≥ quanta means we mis-parsed; don't fabricate a timecode from it.
        let data = rtmdFile(timescale: 30000, delta: 1001, hh: 0, mm: 0, ss: 1, drop: 0, ff: 77)
        #expect(SourceTimingReader.rtmdTimecode(data) == nil)
    }

    @Test func fileWithoutRtmdTrackReturnsNil() {
        let moov = box("moov", box("trak", box("mdia", Data())))
        #expect(SourceTimingReader.rtmdTimecode(moov + box("mdat", Data())) == nil)
        #expect(SourceTimingReader.rtmdTimecode(Data("RIFFxxxxWAVE".utf8)) == nil)
        #expect(SourceTimingReader.rtmdTimecode(Data()) == nil)
    }

    // MARK: - BWF / bext

    private func chunk(_ type: String, _ body: Data) -> Data {
        var out = type.data(using: .ascii)!
        var size = UInt32(body.count).littleEndian
        withUnsafeBytes(of: &size) { out.append(contentsOf: $0) }
        out.append(body)
        if body.count % 2 == 1 { out.append(0) }
        return out
    }

    private func bwfFile(magic: String = "RIFF", sampleRate: UInt32, timeReference: UInt64) -> Data {
        var fmt = Data([1, 0, 2, 0])                     // PCM, stereo
        var sr = sampleRate.littleEndian
        withUnsafeBytes(of: &sr) { fmt.append(contentsOf: $0) }
        fmt += Data(count: 8)                            // byte rate, align, bits

        var bext = Data(count: 338)                      // description/originator/date/time fields
        var ref = timeReference.littleEndian
        withUnsafeBytes(of: &ref) { bext.append(contentsOf: $0) }
        bext += Data(count: 260)                         // version, UMID, loudness, reserved

        let body = Data("WAVE".utf8) + chunk("fmt ", fmt) + chunk("bext", bext) + chunk("data", Data(count: 16))
        return chunk(magic, body).dropFirst(0)           // RIFF size field covers body; close enough for the walker
    }

    @Test func bwfTimeReferenceBecomesSampleTimecode() {
        // The reporter's music master: TimeReference 01:00:00:00 at 48k.
        let data = bwfFile(sampleRate: 48000, timeReference: 172_800_000)
        let tc = SourceTimingReader.bwfTimecode(data)
        #expect(tc == SourceTimecode(frame: 172_800_000, quanta: 48000, dropFrame: false))
        #expect(tc?.seconds == 3600)
    }

    @Test func rf64MagicIsAccepted() {
        let data = bwfFile(magic: "RF64", sampleRate: 48000, timeReference: 2_529_397_698)
        #expect(SourceTimingReader.bwfTimecode(data)?.seconds == 2_529_397_698.0 / 48000.0)
    }

    @Test func zeroTimeReferenceAndNonWavReturnNil() {
        #expect(SourceTimingReader.bwfTimecode(bwfFile(sampleRate: 48000, timeReference: 0)) == nil)
        #expect(SourceTimingReader.bwfTimecode(Data("RIFFxxxxAVI ".utf8)) == nil)
        #expect(SourceTimingReader.bwfTimecode(Data()) == nil)
    }

    @Test func wavWithoutBextReturnsNil() {
        var fmt = Data([1, 0, 2, 0]) + u32le(48000) + Data(count: 8)
        let body = Data("WAVE".utf8) + chunk("fmt ", fmt) + chunk("data", Data(count: 16))
        fmt = Data()
        #expect(SourceTimingReader.bwfTimecode(chunk("RIFF", body)) == nil)
    }

    private func u32le(_ v: UInt32) -> Data {
        var le = v.littleEndian
        return withUnsafeBytes(of: &le) { Data($0) }
    }

    // MARK: - XMEML rescale of sample-based timecode

    @Test func sampleBasedTimecodeRescalesToVideoRate() {
        // BWF 1h @ 48k against a 25fps element → frame 90000, not a 48000fps timecode.
        let source = SourceTimecode(frame: 172_800_000, quanta: 48000, dropFrame: false)
        let tc = XMLExporter.timecodeTags(source: source, videoTimebase: 25, videoNtsc: false)
        #expect(tc.base == 25)
        #expect(tc.frame == 90000)
        #expect(tc.string == "01:00:00:00")
    }

    @Test func sampleBasedTimecodeAgainstNtscRate() {
        // 3600s of wall clock at 29.97: raw frame count = 3600 * 29.97 ≈ 107892.
        let source = SourceTimecode(frame: 172_800_000, quanta: 48000, dropFrame: false)
        let tc = XMLExporter.timecodeTags(source: source, videoTimebase: 30, videoNtsc: true)
        #expect(tc.base == 30)
        #expect(tc.dropFrame)
        #expect(tc.frame == 107892)
        #expect(tc.string == "01;00;00;00")   // DF display catches back up to wall clock
    }
}
