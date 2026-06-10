import SwiftUI

struct StoragePane: View {
    @State private var cacheBytes: Int64 = 0
    @State private var isClearing = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text("Cache")
                        .font(.system(size: AppTheme.FontSize.md))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text("Saved playback previews, waveforms, and filmstrip thumbnails. Safe to clear; they'll rebuild as needed.")
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: AppTheme.Spacing.sm) {
                        Text(displayPath)
                            .font(.system(size: AppTheme.FontSize.xs).monospaced())
                            .foregroundStyle(AppTheme.Text.tertiaryColor)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(formattedSize)
                            .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                            .foregroundStyle(AppTheme.Text.secondaryColor)
                    }
                    .padding(.top, AppTheme.Spacing.xs)
                }

                Spacer(minLength: AppTheme.Spacing.lg)

                Button("Clear cache") {
                    clear()
                }
                .controlSize(.small)
                .disabled(isClearing || cacheBytes == 0)
            }

            Divider()
                .overlay(AppTheme.Border.subtleColor)
        }
        .task { await refresh() }
    }

    private nonisolated static let caches = [ImageVideoGenerator.cache, MediaVisualCache.diskCache]

    private var displayPath: String {
        DiskCache.rootDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var formattedSize: String {
        if isClearing { return "Clearing…" }
        return ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    private func clear() {
        isClearing = true
        Task.detached {
            for cache in Self.caches { cache.clear() }
            await MainActor.run { isClearing = false }
            await refresh()
        }
    }

    private func refresh() async {
        let bytes = await Task.detached {
            Self.caches.reduce(0) { $0 + $1.size() }
        }.value
        cacheBytes = bytes
    }
}
