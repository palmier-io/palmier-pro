import AVFoundation
import SwiftUI

enum ExportMode: String, CaseIterable, Identifiable {
    case video = "MP4 Video"
    case xml = "NLE Timeline"

    var id: String { rawValue }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case h265 = "H.265"
    case prores = "ProRes"

    var id: String { rawValue }
}

struct ExportView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var service = ExportService()
    @State private var mode: ExportMode = .video
    @State private var codec: VideoCodec = .h264
    @State private var resolution: ExportResolution = .r1080p
    @State private var preview: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            // Main content: preview + settings
            HStack(alignment: .top, spacing: 0) {
                previewPanel
                settingsPanel
            }

            Divider().opacity(0.3)

            // Bottom bar
            bottomBar
        }
        .frame(width: 580, height: 340)
        .presentationBackground {
            Color(white: 0.08, opacity: 0.85)
                .background(.ultraThinMaterial)
        }
        .task { loadPreview() }
    }

    // MARK: - Preview (left)

    private var previewPanel: some View {
        ZStack {
            Color(white: 0.05)

            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "film")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .frame(width: 240)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .padding(AppTheme.Spacing.xl)
    }

    // MARK: - Settings (right)

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title
            Text("Export")
                .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)
                .padding(.bottom, AppTheme.Spacing.lg)

            // Format picker
            Picker("", selection: $mode) {
                ForEach(ExportMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.bottom, AppTheme.Spacing.lg)

            // Settings rows
            VStack(spacing: 0) {
                switch mode {
                case .video:
                    settingRow(label: "Codec") {
                        Picker("", selection: $codec) {
                            ForEach(VideoCodec.allCases) { c in
                                Text(c.rawValue).tag(c)
                            }
                        }
                        .labelsHidden()
                    }

                    Divider().opacity(0.2)

                    settingRow(label: "Resolution") {
                        Picker("", selection: $resolution) {
                            ForEach(ExportResolution.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .labelsHidden()
                    }

                    Divider().opacity(0.2)

                    settingRow(label: "Frame Rate") {
                        Text("\(editor.timeline.fps) fps")
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }

                case .xml:
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Exports your timeline as XML for use in other editors.")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)

                        Text("Works with DaVinci Resolve, Premiere Pro, and Final Cut Pro.")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    .padding(.vertical, AppTheme.Spacing.md)
                }
            }

            // Progress
            if service.isExporting {
                VStack(spacing: AppTheme.Spacing.xs) {
                    ProgressView(value: service.progress)
                        .progressViewStyle(.linear)
                    Text("\(Int(service.progress * 100))%")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                }
                .padding(.top, AppTheme.Spacing.md)
            }

            if let error = service.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.top, AppTheme.Spacing.sm)
            }

            Spacer()
        }
        .padding(.top, AppTheme.Spacing.xl)
        .padding(.trailing, AppTheme.Spacing.xl)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            let duration = formatTimecode(frame: editor.timeline.totalFrames, fps: editor.timeline.fps)
            HStack(spacing: AppTheme.Spacing.lg) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "clock")
                    Text(duration)
                }
                if mode == .video {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "doc")
                        Text("~\(estimatedFileSize)")
                    }
                }
                Text("\(editor.timeline.width)×\(editor.timeline.height)")
            }
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.mutedColor)

            Spacer()

            Button("Cancel") { editor.showExportDialog = false }
                .keyboardShortcut(.cancelAction)
            Button("Export") { startExport() }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .disabled(service.isExporting)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, AppTheme.Spacing.xl)
        .padding(.vertical, AppTheme.Spacing.lg)
    }

    // MARK: - Helpers

    private func settingRow<Control: View>(label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            control()
        }
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    private var estimatedFileSize: String {
        let seconds = frameToSeconds(frame: editor.timeline.totalFrames, fps: editor.timeline.fps)
        let bytes = Double(resolution.estimatedBytesPerSecond) * seconds
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", bytes / 1_000_000_000)
        } else {
            return String(format: "%.0f MB", bytes / 1_000_000)
        }
    }

    private var exportFormat: ExportFormat {
        switch mode {
        case .xml: .xml
        case .video:
            switch codec {
            case .h264: .h264
            case .h265: .h265
            case .prores: .prores
            }
        }
    }

    private func loadPreview() {
        for track in editor.timeline.tracks where track.type == .video {
            for clip in track.clips {
                guard let url = editor.mediaResolver.resolveURL(for: clip.mediaRef) else { continue }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.maximumSize = CGSize(width: 480, height: 270)
                generator.appliesPreferredTrackTransform = true
                let time = CMTime(value: CMTimeValue(clip.trimStartFrame), timescale: CMTimeScale(editor.timeline.fps))
                generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { _, image, _, _, _ in
                    if let image {
                        Task { @MainActor in
                            preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                        }
                    }
                }
                return
            }
        }
    }

    private func startExport() {
        let format = exportFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [
            format == .xml
                ? .xml
                : (format == .prores ? .movie : .mpeg4Movie)
        ]
        panel.nameFieldStringValue = "export.\(format.fileExtension)"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                await service.export(
                    timeline: editor.timeline,
                    resolver: editor.mediaResolver,
                    format: format,
                    resolution: resolution,
                    outputURL: url
                )
                if service.error == nil {
                    editor.showExportDialog = false
                }
            }
        }
    }
}
