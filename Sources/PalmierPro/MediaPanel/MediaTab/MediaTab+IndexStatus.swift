import SwiftUI

extension MediaTab {
    var searchIndexStatus: some View {
        MediaSearchIndexStatus(search: editor.searchIndex, mediaAssets: editor.mediaAssets)
    }
}

private struct MediaSearchIndexStatus: View {
    let search: SearchIndexCoordinator
    let mediaAssets: [MediaAsset]

    @ViewBuilder
    var body: some View {
        let model = VisualModelLoader.shared
        switch model.state {
        case .notInstalled where model.enabled && hasIndexableAssets:
            statusButton(icon: "sparkle.magnifyingglass", label: "Smart search") {
                model.download()
            }
            .help("Downloads a \(modelSizeLabel) on-device model so you can search media visually.")
        case .downloading(let fraction):
            statusIndicator("Downloading \(Int(fraction * 100))%",
                            help: "Downloading the on-device model that powers visual search.",
                            progress: fraction)
        case .preparing:
            statusIndicator("Preparing…", help: "Getting the search model ready.")
        case .ready where search.indexingActive:
            statusIndicator("Indexing \(min(search.batchCompleted + 1, search.batchTotal))/\(search.batchTotal)",
                            help: "Analyzing media so you can search it.",
                            progress: search.indexingProgress)
        case .failed where model.enabled:
            statusButton(icon: "exclamationmark.triangle", label: "Retry") { model.download() }
                .help("Visual search model download failed. Check your connection and try again.")
        default:
            EmptyView()
        }
    }

    private var hasIndexableAssets: Bool {
        mediaAssets.contains { $0.type == .video || $0.type == .image }
    }

    private var modelSizeLabel: String {
        let files = SearchIndexConfig.manifest.files
        return ByteCountFormatter.string(fromByteCount: files.imageEncoder.bytes + files.textEncoder.bytes, countStyle: .file)
    }

    private func statusButton(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: AppTheme.Spacing.xxs) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
            .foregroundStyle(AppTheme.Text.secondaryColor)
        }
        .buttonStyle(.plain)
    }

    private func statusIndicator(_ label: String, help: String, progress: Double? = nil) -> some View {
        HStack(spacing: AppTheme.Spacing.xs) {
            if let progress {
                progressRing(progress)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(label)
                .font(.system(size: AppTheme.FontSize.xs))
                .foregroundStyle(AppTheme.Text.tertiaryColor)
        }
        .help(help)
    }

    private func progressRing(_ value: Double) -> some View {
        ZStack {
            Circle()
                .stroke(AppTheme.Border.subtleColor, lineWidth: AppTheme.BorderWidth.medium)
            Circle()
                .trim(from: 0, to: max(min(value, 1), 0.03))
                .stroke(AppTheme.Text.secondaryColor,
                        style: StrokeStyle(lineWidth: AppTheme.BorderWidth.medium, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: AppTheme.IconSize.xxs, height: AppTheme.IconSize.xxs)
        .animation(.linear(duration: AppTheme.Anim.transition), value: value)
    }
}
