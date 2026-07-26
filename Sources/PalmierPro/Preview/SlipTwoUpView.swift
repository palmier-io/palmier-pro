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
        let (start, end) = await SlipFrameLoader.frames(
            inSourceFrame: state.inSourceFrame,
            outSourceFrame: state.outSourceFrame,
            url: state.url,
            fps: state.fps
        )
        guard !Task.isCancelled else { return }
        if let start { inImage = start }
        if let end { outImage = end }
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

/// Decodes the slip two-up preview frames. Nonisolated so the AVFoundation setup and decode
/// run on the cooperative pool, never the UI executor, and both frames come from a single
/// generator per refresh.
private enum SlipFrameLoader {
    static func frames(inSourceFrame: Int, outSourceFrame: Int, url: URL, fps: Int) async -> (start: CGImage?, end: CGImage?) {
        guard fps > 0 else { return (nil, nil) }
        let timescale = CMTimeScale(fps)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 960)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: timescale)
        let inTime = CMTime(value: CMTimeValue(max(0, inSourceFrame)), timescale: timescale)
        let outTime = CMTime(value: CMTimeValue(max(0, outSourceFrame)), timescale: timescale)
        var start: CGImage?
        var end: CGImage?
        for await result in generator.images(for: [inTime, outTime]) {
            guard case let .success(requestedTime, image, _) = result else { continue }
            if CMTimeCompare(requestedTime, inTime) == 0 { start = image }
            if CMTimeCompare(requestedTime, outTime) == 0 { end = image }
        }
        return (start, end)
    }
}
