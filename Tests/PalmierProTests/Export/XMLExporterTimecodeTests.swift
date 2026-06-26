import Testing
@testable import PalmierPro

/// Regression for source-timecode export (DaVinci/Premiere relink by source timecode).
///
/// A QuickTime `tmcd` track carries its own frame quanta and drop-frame flag, which can differ from
/// the video rate (e.g. 30 DF timecode on 59.94p footage). The earlier exporter formatted the start
/// frame using the *video* rate and a drop-frame flag *guessed* from it, so the emitted timecode
/// didn't match the file and DaVinci refused to relink. `timecodeTags` must follow the track.
@Suite("XMLExporter timecode")
struct XMLExporterTimecodeTests {
    typealias Source = XMLExporter.SourceTimecode

    // MARK: - timecodeTags follows the track, not the video rate

    @Test func nonDropSourceEmitsNonDropTimecodeRegardlessOfVideoNtsc() {
        // 29.97 NDF source: start 18:13:40:20 → frame 1968620 at quanta 30, drop-frame FALSE.
        // The video is NTSC (the old code would have forced drop-frame here).
        let tc = XMLExporter.timecodeTags(
            source: Source(frame: 1968620, quanta: 30, dropFrame: false),
            videoTimebase: 30, videoNtsc: true
        )
        #expect(tc.base == 30)
        #expect(tc.ntsc == true)        // 29.97 NDF still rides NTSC
        #expect(tc.dropFrame == false)
        #expect(tc.string == "18:13:40:20")
        #expect(!tc.string.contains(";"))
    }

    @Test func dropFrameSourceOn60pUsesTrackQuantaNotVideoRate() {
        // Fuji 59.94p: tmcd runs at quanta 30 DF; start 00:23:53;.. → frame 42966.
        // Formatting at the video rate (60) gave the wrong 00;11;56;.. — must use quanta 30.
        let tc = XMLExporter.timecodeTags(
            source: Source(frame: 42966, quanta: 30, dropFrame: true),
            videoTimebase: 60, videoNtsc: true
        )
        #expect(tc.base == 30)
        #expect(tc.dropFrame == true)
        #expect(tc.frame == 42966)
        #expect(tc.string == "00;23;53;18")   // 42966 @ 30 DF, matches the file's 00:23:53;36 @ 60
    }

    @Test func cleanThirtyFpsSourceStaysNonNtsc() {
        let tc = XMLExporter.timecodeTags(
            source: Source(frame: 0, quanta: 30, dropFrame: false),
            videoTimebase: 30, videoNtsc: false
        )
        #expect(tc.ntsc == false)
        #expect(tc.string == "00:00:00:00")
    }

    @Test func noTimecodeTrackFallsBackToVideoRateAndZero() {
        // No tmcd → dummy 00:00:00:00 at the video rate; drop-frame guessed from the video rate.
        let tc = XMLExporter.timecodeTags(source: nil, videoTimebase: 30, videoNtsc: true)
        #expect(tc.frame == 0)
        #expect(tc.base == 30)
        #expect(tc.dropFrame == true)   // legacy guess for NTSC 30 when the source is silent
        #expect(tc.string == "00;00;00;00")
    }

    // MARK: - formatTimecode math

    @Test func nonDropFormattingRollsFieldsAtFps() {
        #expect(XMLExporter.formatTimecode(frame: 0, fps: 25, dropFrame: false) == "00:00:00:00")
        // 18:45:23:23 @ 25fps = 1688098.
        #expect(XMLExporter.formatTimecode(frame: 1688098, fps: 25, dropFrame: false) == "18:45:23:23")
        // One full hour at 24fps.
        #expect(XMLExporter.formatTimecode(frame: 24 * 3600, fps: 24, dropFrame: false) == "01:00:00:00")
    }

    @Test func dropFrameSkipsDroppedFrameNumbers() {
        // At 30 DF the first two frame numbers of each non-tenth minute are dropped, so the
        // displayed value runs ahead of the raw count.
        #expect(XMLExporter.formatTimecode(frame: 0, fps: 30, dropFrame: true) == "00;00;00;00")
        #expect(XMLExporter.formatTimecode(frame: 42966, fps: 30, dropFrame: true) == "00;23;53;18")
    }

    @Test func zeroFpsDoesNotCrash() {
        #expect(XMLExporter.formatTimecode(frame: 100, fps: 0, dropFrame: false) == "00:00:00:00")
    }
}
