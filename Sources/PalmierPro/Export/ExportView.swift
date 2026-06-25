import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ExportView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var service = ExportService()
    @State private var mode: ExportMode = .video
    @State private var codec: VideoCodec = .h264
    @State private var resolution: ExportResolution = .matchTimeline
    @State private var preview: NSImage?
    @State private var palmierResult: String?
    @State private var palmierSummary: (collect: Int, missing: Int, bytes: Int64) = (0, 0, 0)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                settingsPanel
                    .frame(width: 360)
                previewPanel
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)

            bottomBar
        }
        .frame(width: 860, height: 560)
        .presentationBackground {
            AppTheme.Background.surfaceColor.opacity(0.85)
                .background(.ultraThinMaterial)
        }
        .task {
            await loadPreview()
            palmierSummary = await computePalmierSummary()
        }
    }

    private func panelHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: AppTheme.FontSize.title2, weight: .light))
            .tracking(AppTheme.Tracking.tight)
            .foregroundStyle(AppTheme.Text.primaryColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppTheme.Spacing.xl)
            .padding(.vertical, AppTheme.Spacing.md)
    }

    // MARK: - Preview (right)

    private var previewPanel: some View {
        ZStack {
            if let preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "film")
                    .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                    .foregroundStyle(AppTheme.Text.mutedColor)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.Background.baseColor)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.sm))
        .padding(AppTheme.Spacing.xl)
    }

    // MARK: - Settings (left)

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            panelHeader("Export")

            VStack(alignment: .leading, spacing: 0) {
            // Settings rows
            VStack(spacing: 0) {
                settingRow(label: "Format") {
                    Picker("", selection: $mode) {
                        ForEach(ExportMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .labelsHidden()
                }

                Divider().opacity(0.2)

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

                        Text("Text overlays, flips, adjustments, effects, and keyframe easing aren't included.")
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppTheme.Spacing.sm)

                case .palmierProject:
                    VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                        Text("Saves a copy of this project with all media bundled inside, so it opens on any machine.")
                            .font(.system(size: AppTheme.FontSize.sm))
                            .foregroundStyle(AppTheme.Text.secondaryColor)

                        if palmierSummary.missing > 0 {
                            Text("\(palmierSummary.missing) media file\(palmierSummary.missing == 1 ? "" : "s") missing — they'll be skipped.")
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Status.errorColor)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, AppTheme.Spacing.sm)
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

            if let palmierResult {
                Text(palmierResult)
                    .font(.caption)
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .padding(.top, AppTheme.Spacing.sm)
            }

            Spacer()
            }
            .padding(AppTheme.Spacing.xl)
        }
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
                switch mode {
                case .video:
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "doc")
                        Text("~\(estimatedFileSize)")
                    }
                    let out = resolution.renderSize(for: CGSize(width: editor.timeline.width, height: editor.timeline.height))
                    Text("\(Int(out.width))×\(Int(out.height))")
                case .xml:
                    Text("\(editor.timeline.width)×\(editor.timeline.height)")
                case .palmierProject:
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "shippingbox")
                        Text("~\(ByteCountFormatter.string(fromByteCount: palmierSummary.bytes, countStyle: .file))")
                    }
                }
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
        let seconds = Double(editor.timeline.totalFrames) / Double(max(1, editor.timeline.fps))
        // Bitrate scales with output pixel area, so any resolution is covered.
        let out = resolution.renderSize(for: CGSize(width: editor.timeline.width, height: editor.timeline.height))
        let megapixels = Double(out.width * out.height) / 1_000_000
        let bytesPerSecPerMP: Double = switch codec {
        case .h264:   0.63e6
        case .h265:   0.32e6
        case .prores: 9.0e6
        }
        let bytesPerSec = bytesPerSecPerMP * max(0.1, megapixels)
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSec * seconds), countStyle: .file)
    }

    private var exportFormat: ExportFormat {
        switch mode {
        case .xml, .palmierProject: .xml   // palmierProject has its own path; never rendered
        case .video: codec.exportFormat
        }
    }

    /// Quick estimate for exporting a Palmier Project
    private func computePalmierSummary() async -> (collect: Int, missing: Int, bytes: Int64) {
        let entries = editor.mediaManifest.entries
        let projectURL = editor.projectURL
        return await Task.detached(priority: .utility) {
            var collect = 0, missing = 0
            var bytes: Int64 = 0
            for entry in entries {
                let url: URL? = switch entry.source {
                case .external(let path): URL(fileURLWithPath: path)
                case .project(let rel): projectURL?.appendingPathComponent(rel)
                }
                guard let url, FileManager.default.fileExists(atPath: url.path) else { missing += 1; continue }
                if case .external = entry.source { collect += 1 }
                bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
            return (collect, missing, bytes)
        }.value
    }

    private func loadPreview() async {
        let timeline = editor.timeline
        let mediaURLs = editor.mediaResolver.expectedURLMap()
        let missingMediaRefs = editor.missingMediaRefs
        let image = await Task.detached(priority: .utility) { () async -> CGImage? in
            for track in timeline.tracks where track.type == .video {
                for clip in track.clips {
                    guard !missingMediaRefs.contains(clip.mediaRef),
                          let url = mediaURLs[clip.mediaRef] else { continue }
                    let asset = AVURLAsset(url: url)
                    guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else { continue }
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.maximumSize = CGSize(width: 480, height: 270)
                    generator.appliesPreferredTrackTransform = true
                    let time = CMTime(value: CMTimeValue(clip.trimStartFrame), timescale: CMTimeScale(timeline.fps))
                    guard let image = try? await generator.image(at: time).image else { continue }
                    return image
                }
            }
            return nil
        }.value
        guard let image, !Task.isCancelled else { return }
        preview = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }

    private func startExport() {
        if mode == .palmierProject { startPalmierExport(); return }
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
                    missingMediaRefs: editor.missingMediaRefs,
                    outputURL: url
                )
                if service.error == nil {
                    editor.showExportDialog = false
                }
            }
        }
    }

    private func startPalmierExport() {
        palmierResult = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(Project.typeIdentifier) ?? .package]
        let base = editor.projectURL?.deletingPathExtension().lastPathComponent ?? Project.defaultProjectName
        panel.nameFieldStringValue = "\(base).\(Project.fileExtension)"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                let report = await service.exportPalmierProject(
                    timeline: editor.timeline,
                    manifest: editor.mediaManifest,
                    generationLog: editor.generationLog,
                    sourceProjectURL: editor.projectURL,
                    outputURL: url
                )
                guard let report, service.error == nil else { return }
                if report.missing.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    editor.showExportDialog = false
                } else {
                    // Keep the dialog open so the user sees what couldn't be included.
                    palmierResult = "Exported, but \(report.missing.count) media file\(report.missing.count == 1 ? "" : "s") were missing and couldn't be included."
                }
            }
        }
    }
}
