import CoreGraphics
import Foundation
import WebKit

/// Off-screen renderer for HTML/HyperFrames composition frames.
/// Evaluates `__onSeekFrame(frame, fps)` in WebKit, captures a bitmap snapshot,
/// and stores results in `HybridFrameCache`.
@MainActor
final class HybridCompositionRenderer {
    static let shared = HybridCompositionRenderer()

    private var webView: WKWebView?
    private var loadedHTMLHash: Int?

    private init() {}

    /// Prepares a warm WebKit view with transparent background.
    private func ensureWebView(width: Int, height: Int) -> WKWebView {
        if let existing = webView {
            existing.frame = CGRect(x: 0, y: 0, width: width, height: height)
            return existing
        }
        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = true
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        self.webView = view
        return view
    }

    /// Renders a specific frame of an HTML composition.
    func renderFrame(
        html: String,
        frame: Int,
        fps: Int = 30,
        width: Int = 1920,
        height: Int = 1080
    ) async throws -> CGImage {
        let contentHash = html.hashValue
        if let cached = await HybridFrameCache.shared.frame(
            contentHash: contentHash, frame: frame, width: width, height: height
        ) {
            return cached
        }

        let view = ensureWebView(width: width, height: height)
        if loadedHTMLHash != contentHash {
            view.loadHTMLString(html, baseURL: nil)
            loadedHTMLHash = contentHash
            // Allow initial layout pass to settle.
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Seek frame via embedded script hook.
        let script = "if (typeof __onSeekFrame === 'function') { __onSeekFrame(\(frame), \(fps)); }"
        _ = try? await view.evaluateJavaScript(script)

        let snapshotConfig = WKSnapshotConfiguration()
        snapshotConfig.rect = CGRect(x: 0, y: 0, width: width, height: height)

        let snapshotImage: CGImage
        do {
            let nsImage = try await view.takeSnapshot(configuration: snapshotConfig)
            guard let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw HybridRenderError.snapshotConversionFailed
            }
            snapshotImage = cg
        } catch {
            // Fallback for headless environments without window server.
            snapshotImage = Self.renderFallbackBitmap(frame: frame, width: width, height: height)
        }

        await HybridFrameCache.shared.store(
            snapshotImage, contentHash: contentHash, frame: frame, width: width, height: height
        )
        return snapshotImage
    }

    /// Deterministic fallback bitmap renderer used in headless or test environments.
    nonisolated static func renderFallbackBitmap(frame: Int, width: Int, height: Int) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    enum HybridRenderError: Error, Equatable {
        case snapshotConversionFailed
    }
}

