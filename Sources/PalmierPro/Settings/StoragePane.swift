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
                    Text("Saved image previews used during playback. Safe to clear — they'll be rebuilt when needed.")
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

                Button("Clear") {
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

    private var displayPath: String {
        let path = ImageVideoGenerator.cacheDirectory.path
        return path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var formattedSize: String {
        if isClearing { return "Clearing…" }
        return ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    private func clear() {
        isClearing = true
        Task.detached {
            try? ImageVideoGenerator.clearCache()
            await MainActor.run { isClearing = false }
            await refresh()
        }
    }

    private func refresh() async {
        let bytes = await Task.detached { ImageVideoGenerator.cacheSize() }.value
        cacheBytes = bytes
    }
}
