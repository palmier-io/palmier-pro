import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import PalmierPro

/// HDR (HEVC Main10) export must bake titles, place them like the SDR path, and report progress.
@Suite("HDR title + progress")
@MainActor
struct HDRTitleProgressTests {

    private func makeTimeline(title: Bool) async throws -> (Timeline, MediaResolver) {
        let size = CGSize(width: 1280, height: 720)
        let blackURL = try await ImageVideoGenerator.blackVideo(size: size)
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(id: "bg", name: "b", type: .video,
            source: .external(absolutePath: blackURL.path), duration: 30.0)]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })
        var tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(id: "bg", mediaRef: "bg", start: 0, duration: 60)])]
        if title {
            var t = Fixtures.clip(id: "t", mediaRef: "", mediaType: .text, start: 0, duration: 60)
            t.textContent = "HELLO"; var st = TextStyle(); st.fontSize = 200; t.textStyle = st
            tracks.append(Fixtures.videoTrack(clips: [t]))
        }
        var tl = Fixtures.timeline(tracks: tracks); tl.width = 1280; tl.height = 720
        return (tl, resolver)
    }

    private func peakLuma(_ url: URL) async throws -> Int {
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)
        let cg = try await gen.image(at: CMTime(seconds: 1, preferredTimescale: 30)).image
        let w = cg.width, h = cg.height, bpr = w*4
        var buf = [UInt8](repeating: 0, count: bpr*h)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var peak = 0
        for i in stride(from: 0, to: buf.count, by: 4) { let l = Int(buf[i])+Int(buf[i+1])+Int(buf[i+2]); if l > peak { peak = l } }
        return peak
    }

    @Test func hdrBakesTitleAndReportsProgress() async throws {
        let (tl, resolver) = try await makeTimeline(title: true)
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("hdrtp-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: outURL) }
        let svc = ExportService()
        let sampler = Task { @MainActor () -> Bool in
            var saw = false
            while svc.progress < 1.0 { if svc.progress > 0 { saw = true }; try? await Task.sleep(for: .milliseconds(20)) }
            return saw
        }
        await svc.export(timeline: tl, resolver: resolver, format: .hevcHDR, resolution: .r720p, outputURL: outURL)
        let sawProgress = await sampler.value
        #expect(svc.error == nil, "\(svc.error ?? "")")
        #expect(sawProgress, "HDR progress stuck at 0")
        let peak = try await peakLuma(outURL)
        print("HDRTP title peak=\(peak)")
        #expect(peak > 150, "HDR title missing (peak=\(peak))")
    }
}
