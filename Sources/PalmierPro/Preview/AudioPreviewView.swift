import SwiftUI

struct AudioPreviewView: View {
    @Environment(EditorViewModel.self) private var editor
    let asset: MediaAsset

    @State private var waveformLevels: [CGFloat] = []
    @State private var transcriptLines: [TranscriptionSegment] = []
    @State private var loadGeneration = 0
    private nonisolated static let waveformBarResolution = 1_024

    var body: some View {
        let waveformProgress = progress
        VStack(spacing: 0) {
            if transcriptLines.isEmpty {
                Spacer()
            } else {
                transcriptPanel
            }
            waveform(progress: waveformProgress)
                .frame(height: transcriptLines.isEmpty ? AppTheme.Spacing.xxl * 3 : AppTheme.Spacing.xxl)
                .padding(.horizontal, AppTheme.Spacing.xxl)
                .padding(.top, transcriptLines.isEmpty ? 0 : AppTheme.Spacing.lg)
                .padding(.bottom, AppTheme.Spacing.lg)
            if transcriptLines.isEmpty {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.previewCanvasColor)
        .task(id: assetIdentity) {
            await loadContent()
        }
        .task(id: assetIdentity) {
            let identity = assetIdentity
            let url = asset.url
            for await notification in NotificationCenter.default.notifications(named: .transcriptCacheDidStore) {
                guard !Task.isCancelled else { return }
                guard let stored = notification.object as? URL, stored.path == url.path else { continue }
                await refreshTranscript(for: url, identity: identity, generation: loadGeneration)
            }
        }
        .task(id: assetIdentity) {
            for await notification in NotificationCenter.default.notifications(named: .mediaVisualCacheDidInvalidate) {
                guard !Task.isCancelled else { return }
                if let mediaRef = notification.object as? String, mediaRef != asset.id { continue }
                await loadContent()
            }
        }
    }

    private var assetIdentity: String { "\(asset.id)|\(asset.url.path)" }

    private var progress: CGFloat {
        let duration = editor.activePreviewDurationFrames
        guard duration > 0 else { return 0 }
        return min(1, max(0, CGFloat(editor.playheadState.sourceFrame) / CGFloat(duration)))
    }

    nonisolated static func lines(from transcript: TranscriptionResult?) -> [TranscriptionSegment] {
        guard let transcript else { return [] }
        let segments = transcript.segments.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if !segments.isEmpty { return segments }
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? [] : [TranscriptionSegment(text: text, start: 0, end: .infinity)]
    }

    private var activeLineIndex: Int? {
        Self.activeLineIndex(
            at: Double(editor.playheadState.sourceFrame) / Double(max(1, editor.timeline.fps)),
            in: transcriptLines
        )
    }

    nonisolated static func activeLineIndex(at time: Double, in lines: [TranscriptionSegment]) -> Int? {
        lines.lastIndex { time >= $0.start && time < $0.end }
    }

    private var transcriptPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
                let active = activeLineIndex
                ForEach(transcriptLines.indices, id: \.self) { index in
                    let isActive = index == active
                    Text(verbatim: transcriptLines[index].text)
                        .font(.system(
                            size: AppTheme.FontSize.mdLg,
                            weight: isActive ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.regular
                        ))
                        .foregroundStyle(
                            isActive ? AppTheme.MediaOverlay.primaryColor : AppTheme.MediaOverlay.tertiaryColor
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xxl)
            .padding(.vertical, AppTheme.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
    }

    private func waveform(progress: CGFloat) -> some View {
        Group {
            if waveformLevels.isEmpty {
                Image(systemName: "waveform")
                    .font(.system(size: AppTheme.FontSize.xl))
                    .foregroundStyle(AppTheme.MediaOverlay.mutedColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Canvas { context, size in
                    drawWaveform(in: &context, size: size, progress: progress)
                }
            }
        }
    }

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize, progress: CGFloat) {
        guard size.width > 2, size.height > 2, !waveformLevels.isEmpty else { return }
        let barWidth = AppTheme.Spacing.xxs
        let barGap = AppTheme.BorderWidth.thin
        let step = barWidth + barGap
        let barCount = max(1, Int((size.width + barGap) / step))
        let progressX = size.width * progress

        for i in 0..<barCount {
            let level = waveformLevels[min(waveformLevels.count - 1, i * waveformLevels.count / barCount)]
            let height = max(AppTheme.BorderWidth.medium, level * size.height * 0.9)
            let x = CGFloat(i) * step
            let rect = CGRect(
                x: x,
                y: (size.height - height) / 2,
                width: barWidth,
                height: height
            )
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: .color(AppTheme.MediaOverlay.primaryColor.opacity(
                    x + barWidth <= progressX ? AppTheme.Opacity.prominent : AppTheme.Opacity.medium
                ))
            )
        }
    }

    /// Mean loudness per bar, contrast-stretched so dynamics stay visible at any mastering level.
    nonisolated static func barLevels(samples: [Float], barCount: Int) -> [CGFloat] {
        guard barCount > 0, !samples.isEmpty else { return [] }
        let levels: [CGFloat] = (0..<barCount).map { i in
            let start = i * samples.count / barCount
            let end = min(samples.count, max(start + 1, (i + 1) * samples.count / barCount))
            let quietness = samples[start..<end].reduce(0, +) / Float(end - start)
            return CGFloat(1 - quietness)
        }
        guard let minLevel = levels.min(), let maxLevel = levels.max(),
              maxLevel - minLevel > 0.05 else { return levels }
        let floor: CGFloat = 0.08
        return levels.map { floor + (1 - floor) * ($0 - minLevel) / (maxLevel - minLevel) }
    }

    private func loadContent() async {
        loadGeneration &+= 1
        let generation = loadGeneration
        let identity = assetIdentity
        let url = asset.url
        waveformLevels = []
        transcriptLines = []
        async let waveform = editor.mediaVisualCache.waveform(for: asset)
        await refreshTranscript(for: url, identity: identity, generation: generation)
        let loadedSamples = await waveform
        guard !Task.isCancelled, assetIdentity == identity, loadGeneration == generation else { return }
        let snapshot = loadedSamples ?? []
        let levels = await Task.detached(priority: .utility) {
            Self.barLevels(
                samples: snapshot,
                barCount: min(Self.waveformBarResolution, snapshot.count)
            )
        }.value
        guard !Task.isCancelled, assetIdentity == identity, loadGeneration == generation else { return }
        waveformLevels = levels
    }

    private func refreshTranscript(for url: URL, identity: String, generation: Int) async {
        guard let cachedTranscript = await TranscriptCache.shared.cachedTranscript(for: url),
              !Task.isCancelled,
              assetIdentity == identity,
              loadGeneration == generation else { return }
        transcriptLines = Self.lines(from: cachedTranscript)
    }
}
