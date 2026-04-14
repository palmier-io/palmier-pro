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
        VStack(spacing: 0) {
            // Header
            VStack(spacing: AppTheme.Spacing.md) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .glassEffect(.regular.tint(Color.accentColor.opacity(0.1)), in: .circle)

                VStack(spacing: 2) {
                    Text("Export")
                        .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                        .foregroundStyle(AppTheme.Text.primaryColor)

                    Text("\(editor.timeline.width)×\(editor.timeline.height) · \(editor.timeline.fps)fps")
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .padding(.top, AppTheme.Spacing.xl)
            .padding(.bottom, AppTheme.Spacing.lg)

            // Format picker
            Picker("", selection: $mode) {
                ForEach(ExportMode.allCases) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.bottom, AppTheme.Spacing.lg)

            // Settings
            VStack(spacing: AppTheme.Spacing.md) {
                switch mode {
                case .video:
                    settingCard {
                        settingRow(icon: "film", label: "Codec") {
                            Picker("", selection: $codec) {
                                ForEach(VideoCodec.allCases) { c in
                                    Text(c.rawValue).tag(c)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }
                    }

                    settingCard {
                        settingRow(icon: "rectangle.split.3x3", label: "Resolution") {
                            Picker("", selection: $resolution) {
                                ForEach(ExportResolution.allCases) { p in
                                    Text(p.rawValue).tag(p)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 140)
                        }
                    }

                case .xml:
                    settingCard {
                        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                            Text("Exports your timeline as XML for use in other editors.")
                                .font(.system(size: AppTheme.FontSize.sm))
                                .foregroundStyle(AppTheme.Text.secondaryColor)

                            Text("Works with DaVinci Resolve, Premiere Pro, and Final Cut Pro.")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                    }
                }
            }
            .padding(.horizontal, AppTheme.Spacing.xl)

            Spacer().frame(height: AppTheme.Spacing.lg)

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
                .padding(.horizontal, AppTheme.Spacing.xl)
            }

            if let error = service.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, AppTheme.Spacing.xl)
            }

            // Summary
            HStack(spacing: AppTheme.Spacing.lg) {
                let duration = formatTimecode(frame: editor.timeline.totalFrames, fps: editor.timeline.fps)
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
                Spacer()
            }
            .font(.system(size: AppTheme.FontSize.xs))
            .foregroundStyle(AppTheme.Text.mutedColor)
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.bottom, AppTheme.Spacing.lg)

            // Actions
            HStack {
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
            .padding(.bottom, AppTheme.Spacing.xl)
        }
        .frame(width: 380)
    }

    private func settingCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(AppTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AppTheme.Radius.sm)
                    .fill(Color.white.opacity(0.04))
            )
    }

    private func settingRow<Control: View>(icon: String, label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Image(systemName: icon)
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .frame(width: 16)
            Text(label)
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)
            Spacer()
            control()
        }
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
