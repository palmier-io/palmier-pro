import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import PalmierPro

/// Diagnostic: where does HDR export brightness explode? Feeds a known 50% grey through each
/// path and reads back the encoded center pixel + color tags.
@Suite("HDR color diagnostic")
@MainActor
struct HDRColorDiag {

    /// Solid mid-grey (sRGB code 128) image written to a temp PNG.
    private func greyImageURL(_ size: CGSize) throws -> URL {
        let w = Int(size.width), h = Int(size.height)
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let cg = ctx.makeImage()!
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grey-\(UUID().uuidString).png")
        let dst = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, cg, nil)
        CGImageDestinationFinalize(dst)
        return url
    }

    /// Read first-frame center pixel of `url` as BGRA, plus the video track's transfer function.
    private func probe(_ url: URL) async throws -> (r: Int, g: Int, b: Int, transfer: String) {
        let asset = AVURLAsset(url: url)
        let track = try await asset.loadTracks(withMediaType: .video).first!
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        reader.add(out); reader.startReading()
        guard let sample = out.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sample) else {
            return (-1, -1, -1, "no-frame")
        }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
        let i = (h/2)*bpr + (w/2)*4
        let b = Int(base[i]), g = Int(base[i+1]), r = Int(base[i+2])
        CVPixelBufferUnlockBaseAddress(pb, .readOnly)
        let fmt = try await track.load(.formatDescriptions).first
        var transfer = "?"
        if let fmt, let ext = CMFormatDescriptionGetExtension(fmt, extensionKey: kCMFormatDescriptionExtension_TransferFunction) {
            transfer = "\(ext)"
        }
        return (r, g, b, transfer)
    }

    private func export(format: ExportFormat, title: Bool) async throws -> URL {
        let size = CGSize(width: 640, height: 360)
        let greyURL = try greyImageURL(size)
        var manifest = MediaManifest()
        manifest.entries = [MediaManifestEntry(id: "grey", name: "grey", type: .image,
            source: .external(absolutePath: greyURL.path), duration: 5.0)]
        let resolver = MediaResolver(manifest: { manifest }, projectURL: { nil })
        let clip = Fixtures.clip(id: "c", mediaRef: "grey", mediaType: .image, start: 0, duration: 30)
        var tracks = [Fixtures.videoTrack(clips: [clip])]
        if title {
            var t = Fixtures.clip(id: "t", mediaRef: "", mediaType: .text, start: 0, duration: 30)
            t.textContent = "HI"; var st = TextStyle(); st.fontSize = 80; t.textStyle = st
            t.transform = Transform(centerX: 0.85, centerY: 0.85, width: 0.2, height: 0.2)
            tracks.append(Fixtures.videoTrack(clips: [t]))
        }
        var timeline = Fixtures.timeline(tracks: tracks)
        timeline.width = 640; timeline.height = 360
        let ext = format == .hevcHDR ? "mov" : "mp4"
        let outURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cd-\(UUID().uuidString).\(ext)")
        let svc = ExportService()
        await svc.export(timeline: timeline, resolver: resolver, format: format, resolution: .r720p, outputURL: outURL)
        #expect(svc.error == nil, "\(svc.error ?? "")")
        return outURL
    }

    @Test func compareGreyAcrossPaths() async throws {
        let sdr = try await probe(try await export(format: .h264, title: false))
        let hdrDirect = try await probe(try await export(format: .hevcHDR, title: false))
        let hdrProc = try await probe(try await export(format: .hevcHDR, title: true))
        print("CD sdr        rgb=(\(sdr.r),\(sdr.g),\(sdr.b)) xfer=\(sdr.transfer)")
        print("CD hdr-direct rgb=(\(hdrDirect.r),\(hdrDirect.g),\(hdrDirect.b)) xfer=\(hdrDirect.transfer)")
        print("CD hdr-proc   rgb=(\(hdrProc.r),\(hdrProc.g),\(hdrProc.b)) xfer=\(hdrProc.transfer)")
        // HDR must be tagged HLG and have its SDR midtones CONVERTED (not relabeled). A 50% grey
        // that stays at ~SDR code value while tagged HLG is the blown-out bug; converted grey
        // tone-maps back near the SDR reference, not far brighter.
        #expect(hdrDirect.transfer.contains("HLG"))
        #expect(hdrDirect.g <= sdr.g + 6, "HDR grey not converted — blown out (hdr=\(hdrDirect.g) sdr=\(sdr.g))")
        #expect(hdrDirect.g > 60, "HDR grey crushed (hdr=\(hdrDirect.g))")
        #expect(abs(hdrProc.g - hdrDirect.g) <= 6, "title pump shifts the picture brightness")
    }
}
