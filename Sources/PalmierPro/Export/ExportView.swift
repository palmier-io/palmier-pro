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

    var body: some View {
        VStack(spacing: AppTheme.Spacing.xl) {
            Text("Export")
                .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                .foregroundStyle(AppTheme.Text.primaryColor)

            Picker("", selection: $mode) {
                ForEach(ExportMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)

            switch mode {
            case .video:
                Grid(alignment: .leading, verticalSpacing: AppTheme.Spacing.lg) {
                    GridRow {
                        Text("Codec")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                            .gridColumnAlignment(.trailing)
                        Picker("", selection: $codec) {
                            ForEach(VideoCodec.allCases) { c in
                                Text(c.rawValue).tag(c)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                    GridRow {
                        Text("Resolution")
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                        Picker("", selection: $resolution) {
                            ForEach(ExportResolution.allCases) { p in
                                Text(p.rawValue).tag(p)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }

            case .xml:
                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    Text("Exports your timeline as XML for use in other editors.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.secondaryColor)

                    Text("Works with DaVinci Resolve, Premiere Pro, and Final Cut Pro.")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }

            if service.isExporting {
                ProgressView(value: service.progress)
                    .progressViewStyle(.linear)
                Text("\(Int(service.progress * 100))%")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.Text.secondaryColor)
            }

            if let error = service.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: AppTheme.Spacing.lg) {
                let duration = formatTimecode(frame: editor.timeline.totalFrames, fps: editor.timeline.fps)
                Label("Duration: \(duration)", systemImage: "clock")
                if mode == .video {
                    Label("Size: ~\(estimatedFileSize)", systemImage: "doc")
                }
                Spacer()
            }
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.tertiaryColor)

            HStack {
                Spacer()
                Button("Cancel") { editor.showExportDialog = false }
                    .keyboardShortcut(.cancelAction)
                Button("Export") { startExport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.isExporting)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AppTheme.Spacing.xl)
        .frame(width: 360)
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
                    mediaAssets: editor.mediaAssets,
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
