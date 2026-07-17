import AVFoundation
import SwiftUI

/// Viewer two-up state published while a slip drag is active.
struct SlipPreviewState: Equatable {
    let url: URL
    let inSourceFrame: Int
    let outSourceFrame: Int
    let fps: Int
}

/// FCP-style two-up: the slipped clip's new first and last frame, updating live during the drag.
struct SlipTwoUpView: View {
    let state: SlipPreviewState

    @State private var loader = SlipFrameLoader()
    @State private var inImage: CGImage?
    @State private var outImage: CGImage?
    @State private var pendingState: SlipPreviewState?
    @State private var loaderTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black
            HStack(spacing: AppTheme.Spacing.xxs) {
                pane(image: inImage, label: "Start", frame: state.inSourceFrame)
                pane(image: outImage, label: "End", frame: state.outSourceFrame)
            }
        }
        .onAppear {
            enqueue(state)
        }
        .onChange(of: state) { _, newState in
            enqueue(newState)
        }
        .onDisappear {
            loaderTask?.cancel()
            loaderTask = nil
            pendingState = nil
        }
        .allowsHitTesting(false)
    }

    private func enqueue(_ state: SlipPreviewState) {
        pendingState = state
        guard loaderTask == nil else { return }
        loaderTask = Task { @MainActor in
            while let state = pendingState {
                pendingState = nil
                await load(state)
                try? await Task.sleep(for: AppTheme.Anim.slipPreviewRefresh)
                guard !Task.isCancelled else { break }
            }
            loaderTask = nil
        }
    }

    private func load(_ state: SlipPreviewState) async {
        loader.prepare(url: state.url, fps: state.fps)
        async let start = loader.frame(at: state.inSourceFrame)
        async let end = loader.frame(at: state.outSourceFrame)
        let (i, o) = await (start, end)
        guard !Task.isCancelled else { return }
        if let i { inImage = i }
        if let o { outImage = o }
    }

    private func pane(image: CGImage?, label: String, frame: Int) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: AppTheme.Spacing.xs) {
                Text(label)
                    .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.semibold))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(formatTimecode(frame: frame, fps: state.fps))
                    .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }
            .padding(.horizontal, AppTheme.Spacing.sm)
            .padding(.vertical, AppTheme.Spacing.xxs)
            .background(Color.black.opacity(AppTheme.Opacity.strong), in: RoundedRectangle(cornerRadius: AppTheme.Radius.xs))
            .padding(AppTheme.Spacing.sm)
        }
        .clipped()
    }
}

@MainActor
private final class SlipFrameLoader {
    private var url: URL?
    private var fps: Int = 30
    private var asset: AVURLAsset?

    func prepare(url: URL, fps: Int) {
        guard url != self.url || fps != self.fps else { return }
        self.url = url
        self.fps = fps
        asset = AVURLAsset(url: url)
    }

    func frame(at sourceFrame: Int) async -> CGImage? {
        guard let asset, fps > 0 else { return nil }
        // Fresh generator per request: AVAssetImageGenerator isn't Sendable, a local stays region-isolated.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: CMTimeScale(fps))
        let time = CMTime(value: CMTimeValue(max(0, sourceFrame)), timescale: CMTimeScale(fps))
        return try? await generator.image(at: time).image
    }
}
