import Testing
import AVFoundation
@testable import PalmierPro

@Suite("HDR export")
struct HDRExportTests {

    @Test func encodesTenBitHDRFromSource() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let src = env["HDR_SRC"], FileManager.default.fileExists(atPath: src) else { return }
        let outPath = env["HDR_OUT"] ?? (NSTemporaryDirectory() + "hdr-out.mov")

        let asset = AVURLAsset(url: URL(fileURLWithPath: src))
        let comp = AVMutableComposition()
        guard let srcV = try await asset.loadTracks(withMediaType: .video).first else {
            Issue.record("source has no video track"); return
        }
        let dur = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero,
                                duration: CMTimeMinimum(dur, CMTime(seconds: 2, preferredTimescale: 600)))
        let compV = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        try compV.insertTimeRange(range, of: srcV, at: .zero)
        if let srcA = try await asset.loadTracks(withMediaType: .audio).first {
            let compA = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try? compA.insertTimeRange(range, of: srcA, at: .zero)
        }

        let vc = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: comp)
        vc.renderSize = CGSize(width: 1920, height: 1080)

        let out = URL(fileURLWithPath: outPath)
        try await HDRVideoExporter.export(
            .init(composition: comp, videoComposition: vc, audioMix: nil),
            renderSize: vc.renderSize, fps: 30, transfer: .hlg, to: out
        )

        #expect(FileManager.default.fileExists(atPath: outPath))
        let size = (try FileManager.default.attributesOfItem(atPath: outPath)[.size] as? Int) ?? 0
        #expect(size > 10_000, "output suspiciously small (\(size) bytes)")
    }
}
