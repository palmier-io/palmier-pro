import AppKit
import SwiftUI
import WebKit

/// NSViewRepresentable wrapper around WKWebView for live HTML/motion preview.
@MainActor
struct HyperframesLivePreviewView: NSViewRepresentable {
    let html: String
    let currentFrame: Int
    var fps: Int = 30

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator

        context.coordinator.lastHTML = html
        context.coordinator.lastFrame = currentFrame
        webView.loadHTMLString(html, baseURL: nil)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            nsView.loadHTMLString(html, baseURL: nil)
        }
        if context.coordinator.lastFrame != currentFrame {
            context.coordinator.lastFrame = currentFrame
            context.coordinator.seek(to: currentFrame, in: nsView, fps: fps)
        }
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        var lastFrame: Int?

        func seek(to frame: Int, in webView: WKWebView, fps: Int) {
            let time = Double(frame) / Double(max(1, fps))
            let script = """
            (function() {
                const payload = { frame: \(frame), time: \(time) };
                if (typeof window.__onSeekFrame === 'function') {
                    window.__onSeekFrame(\(frame), \(time));
                }
                window.postMessage(payload, '*');
            })();
            """
            webView.evaluateJavaScript(script, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let frame = lastFrame {
                seek(to: frame, in: webView, fps: 30)
            }
        }
    }
}

