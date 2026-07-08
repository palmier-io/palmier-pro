import SwiftUI
import UniformTypeIdentifiers

enum ExportDestination: String, CaseIterable, Identifiable {
    case video = "Video"
    case timeline = "Timeline"
    case palmierProject = "Palmier Project"

    var id: String { rawValue }
}

enum TimelineExportFormat: String, CaseIterable, Identifiable {
    case xmeml = "XMEML"
    case fcpxml = "FCPXML"

    var id: String { rawValue }

    var exportFormat: ExportFormat {
        switch self {
        case .xmeml: .xml
        case .fcpxml: .fcpxml
        }
    }

    var extensionLabel: String {
        switch self {
        case .xmeml: ".xml"
        case .fcpxml: ".fcpxml"
        }
    }

    var versionLabel: String {
        switch self {
        case .xmeml: "v4"
        case .fcpxml: ""   // user-selectable; shown via the version picker
        }
    }

    var summary: String {
        switch self {
        case .xmeml: "Older interchange format, best when Premiere Pro is the destination. Supports basic edits and keyframes, but not text, color, or effects."
        case .fcpxml: "Newer timeline format with better support for DaVinci Resolve and Final Cut Pro. Supports basic edits, keyframes, and text, but not color or effects."
        }
    }

    var compatibilityLabel: String {
        switch self {
        case .xmeml: "Premiere Pro and DaVinci Resolve"
        case .fcpxml: "DaVinci Resolve and Final Cut Pro"
        }
    }
}

struct ExportView: View {
    @Environment(EditorViewModel.self) var editor
    @State private var service = ExportService()
    @State private var destination: ExportDestination = .video
    @State private var timelineFormat: TimelineExportFormat = .fcpxml
    @State private var fcpxmlVersion: FCPXMLVersion = .default
    @State private var fcpxmlTarget: FCPXMLTarget = .default
    @State private var codec: VideoCodec = .h264
    @State private var resolution: ExportResolution = .matchTimeline
    @State private var palmierResult: String?
    @State private var palmierSummary: (collect: Int, missing: Int, bytes: Int64) = (0, 0, 0)
    @State private var selectedTimelineId: String?

    private var exportTimeline: Timeline {
        selectedTimelineId.flatMap { editor.timeline(for: $0) } ?? editor.timeline
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsPanel
            bottomBar
        }
        .frame(width: AppTheme.Export.sheetWidth, height: AppTheme.Export.sheetHeight)
        .presentationBackground {
            AppTheme.Background.surfaceColor.opacity(0.85)
                .background(.ultraThinMaterial)
        }
        .task {
            selectedTimelineId = editor.activeTimelineId
            palmierSummary = computePalmierSummary()
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

    // MARK: - Settings

    private var settingsPanel: some View {
        VStack(spacing: 0) {
            panelHeader("Export")

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    destinationPicker

                    Divider().opacity(AppTheme.Opacity.moderate)

                    if editor.timelines.count > 1, destination != .palmierProject {
                        settingRow(label: "Timeline") {
                            Picker("", selection: $selectedTimelineId) {
                                ForEach(editor.timelines) { timeline in
                                    Text(timeline.name).tag(timeline.id as String?)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }

                        Divider().opacity(AppTheme.Opacity.moderate)
                    }

                    switch destination {
                    case .video:
                        videoSettings
                    case .timeline:
                        timelineSettings
                    case .palmierProject:
                        palmierProjectSettings
                    }
                }

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
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.errorColor)
                        .padding(.top, AppTheme.Spacing.sm)
                }

                if let palmierResult {
                    Text(palmierResult)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .padding(.top, AppTheme.Spacing.sm)
                }

                Spacer()
            }
            .padding(AppTheme.Spacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var destinationPicker: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
            Text("Destination")
                .font(.system(size: AppTheme.FontSize.md))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            HStack(spacing: AppTheme.Spacing.lg) {
                ForEach(ExportDestination.allCases) { destination in
                    destinationButton(destination)
                }
            }
        }
        .padding(.vertical, AppTheme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var videoSettings: some View {
        VStack(spacing: 0) {
            settingRow(label: "Codec") {
                Picker("", selection: $codec) {
                    ForEach(VideoCodec.allCases) { codec in
                        Text(codec.rawValue).tag(codec)
                    }
                }
                .labelsHidden()
            }

            Divider().opacity(AppTheme.Opacity.moderate)

            settingRow(label: "File Type") {
                Text(codec.containerLabel)
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }

            Divider().opacity(AppTheme.Opacity.moderate)

            settingRow(label: "Resolution") {
                Picker("", selection: $resolution) {
                    ForEach(ExportResolution.allCases) { resolution in
                        Text(resolution.rawValue).tag(resolution)
                    }
                }
                .labelsHidden()
            }

            Divider().opacity(AppTheme.Opacity.moderate)

            settingRow(label: "Frame Rate") {
                Text("\(exportTimeline.fps) fps")
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
        }
    }

    private var timelineSettings: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            Text("Timeline Format")
                .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                .foregroundStyle(AppTheme.Text.secondaryColor)
                .padding(.top, AppTheme.Spacing.md)

            VStack(spacing: AppTheme.Spacing.sm) {
                ForEach(TimelineExportFormat.allCases) { format in
                    timelineFormatButton(format)
                }
            }
        }
        .padding(.vertical, AppTheme.Spacing.xs)
    }

    @ViewBuilder
    private var fcpxmlVersionRow: some View {
        Divider().opacity(AppTheme.Opacity.moderate)
        HStack(spacing: AppTheme.Spacing.sm) {
            Text("For")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Picker("", selection: $fcpxmlTarget) {
                ForEach(FCPXMLTarget.allCases) { target in
                    Text(target.displayName).tag(target)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .font(.system(size: AppTheme.FontSize.xs))
            .fixedSize()
            Text("Version")
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
            Picker("", selection: $fcpxmlVersion) {
                ForEach(FCPXMLVersion.allCases) { version in
                    Text(version.rawValue).tag(version)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .font(.system(size: AppTheme.FontSize.xs))
            .fixedSize()
            Text(fcpxmlVersion.compatibilityNote)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, AppTheme.IconSize.sm + AppTheme.Spacing.md)
    }

    private var palmierProjectSettings: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            Text("Saves a copy of this project with all media bundled inside, so it opens on any machine.")
                .font(.system(size: AppTheme.FontSize.sm))
                .foregroundStyle(AppTheme.Text.secondaryColor)

            if palmierSummary.missing > 0 {
                Text("\(palmierSummary.missing) media file\(palmierSummary.missing == 1 ? "" : "s") missing - they'll be skipped.")
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Status.errorColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, AppTheme.Spacing.sm)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            let duration = formatTimecode(frame: exportTimeline.totalFrames, fps: exportTimeline.fps)
            HStack(spacing: AppTheme.Spacing.lg) {
                HStack(spacing: AppTheme.Spacing.xs) {
                    Image(systemName: "clock")
                    Text(duration)
                }
                switch destination {
                case .video:
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "doc")
                        Text("~\(estimatedFileSize)")
                    }
                    let out = resolution.renderSize(for: CGSize(width: exportTimeline.width, height: exportTimeline.height))
                    Text("\(Int(out.width))×\(Int(out.height))")
                    Text(codec.containerLabel)
                case .timeline:
                    Text("\(exportTimeline.width)×\(exportTimeline.height)")
                    Text(timelineFormat.extensionLabel)
                case .palmierProject:
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Image(systemName: "shippingbox")
                        Text("~\(ByteCountFormatter.string(fromByteCount: palmierSummary.bytes, countStyle: .file))")
                    }
                    Text(".\(Project.fileExtension)")
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

    private func destinationButton(_ option: ExportDestination) -> some View {
        let selected = destination == option
        return Button {
            destination = option
        } label: {
            HStack(spacing: AppTheme.Spacing.sm) {
                RadioIndicator(selected: selected)

                Text(option.rawValue)
                    .font(.system(size: AppTheme.FontSize.md, weight: selected ? AppTheme.FontWeight.semibold : AppTheme.FontWeight.medium))
                    .foregroundStyle(selected ? AppTheme.Text.primaryColor : AppTheme.Text.secondaryColor)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .padding(.horizontal, AppTheme.Spacing.xs)
            .padding(.vertical, AppTheme.Spacing.smMd)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func timelineFormatButton(_ format: TimelineExportFormat) -> some View {
        let selected = timelineFormat == format
        return VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.medium))
                    .foregroundStyle(selected ? AppTheme.Accent.primary : AppTheme.Text.mutedColor)
                    .frame(width: AppTheme.IconSize.sm, height: AppTheme.IconSize.sm)

                VStack(alignment: .leading, spacing: AppTheme.Spacing.sm) {
                    HStack(spacing: AppTheme.Spacing.xs) {
                        Text(format.rawValue)
                            .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.semibold))
                            .foregroundStyle(AppTheme.Text.primaryColor)
                        Text(format.extensionLabel)
                            .font(.system(size: AppTheme.FontSize.xs))
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                        if !format.versionLabel.isEmpty {
                            Text(format.versionLabel)
                                .font(.system(size: AppTheme.FontSize.xs))
                                .foregroundStyle(AppTheme.Text.tertiaryColor)
                        }
                    }

                    Text(format.summary)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Compatibility: \(format.compatibilityLabel)")
                        .font(.system(size: AppTheme.FontSize.xs, weight: AppTheme.FontWeight.medium))
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { timelineFormat = format }

            if selected && format == .fcpxml {
                fcpxmlVersionRow
            }
        }
        .padding(AppTheme.Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .fill(selected ? AppTheme.Background.prominentColor : AppTheme.Background.raisedColor)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Radius.sm, style: .continuous)
                .strokeBorder(selected ? AppTheme.Border.primaryColor : AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.thin)
        }
    }

    private var estimatedFileSize: String {
        let seconds = Double(exportTimeline.totalFrames) / Double(max(1, exportTimeline.fps))
        // Bitrate scales with output pixel area, so any resolution (incl. 2K / native) is covered.
        let out = resolution.renderSize(for: CGSize(width: exportTimeline.width, height: exportTimeline.height))
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
        switch destination {
        case .timeline: timelineFormat.exportFormat
        case .palmierProject: .xml   // Palmier Project has its own path; never rendered.
        case .video: codec.exportFormat
        }
    }

    /// Quick estimate for exporting a Palmier Project
    private func computePalmierSummary() -> (collect: Int, missing: Int, bytes: Int64) {
        var collect = 0, missing = 0
        var bytes: Int64 = 0
        for entry in editor.mediaManifest.entries {
            let url: URL? = switch entry.source {
            case .external(let path): URL(fileURLWithPath: path)
            case .project(let rel): editor.projectURL?.appendingPathComponent(rel)
            }
            guard let url, FileManager.default.fileExists(atPath: url.path) else { missing += 1; continue }
            if case .external = entry.source { collect += 1 }
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return (collect, missing, bytes)
    }

    private func startExport() {
        if destination == .palmierProject { startPalmierExport(); return }
        let format = exportFormat
        let panel = NSSavePanel()
        let contentType: UTType = switch format {
        case .xml:
            .xml
        case .fcpxml:
            UTType(filenameExtension: "fcpxml") ?? .xml
        case .prores:
            .movie
        case .h264, .h265:
            .mpeg4Movie
        }
        panel.allowedContentTypes = [contentType]
        panel.nameFieldStringValue = "\(exportTimeline.name).\(format.fileExtension)"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                await service.export(
                    timeline: exportTimeline,
                    resolver: editor.mediaResolver,
                    resolveTimeline: editor.timelineResolver(),
                    format: format,
                    resolution: resolution,
                    fcpxmlVersion: fcpxmlVersion,
                    fcpxmlTarget: fcpxmlTarget,
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
                    projectFile: editor.projectFileSnapshot(),
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
