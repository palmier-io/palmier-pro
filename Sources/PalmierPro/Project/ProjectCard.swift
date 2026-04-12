import SwiftUI

struct ProjectCard: View {
    let entry: ProjectEntry
    let onOpen: (URL) -> Void
    let onRemove: (URL) -> Void

    @State private var isHovered = false
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color(white: 0.15), Color(white: 0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film")
                        .font(.system(size: 28))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }

                if !entry.isAccessible {
                    Color.black.opacity(0.6)

                    VStack(spacing: 4) {
                        Image(systemName: "questionmark.folder")
                            .font(.system(size: 22))
                        Text("Not Found")
                            .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                    }
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .frame(height: 120)
            .clipped()
            .onTapGesture {
                if entry.isAccessible { onOpen(entry.url) }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(entry.isAccessible ? AppTheme.Text.secondaryColor : AppTheme.Text.mutedColor)
                    .lineLimit(1)

                Text(entry.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(Self.relativeString(for: entry.createdDate))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(white: isHovered ? 0.16 : 0.12))
        .opacity(entry.isAccessible ? 1.0 : 0.6)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.Radius.md)
                .strokeBorder(
                    isHovered ? Color.white.opacity(0.15) : AppTheme.Border.subtleColor,
                    lineWidth: 1
                )
        )
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeOut(duration: AppTheme.Anim.hover), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            if entry.isAccessible {
                Button("Open") { onOpen(entry.url) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(entry.url.path, inFileViewerRootedAtPath: entry.url.deletingLastPathComponent().path)
                }
                Divider()
            }
            Button("Remove from Recents") { onRemove(entry.url) }
        }
        .task { loadThumbnail() }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static func relativeString(for date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func loadThumbnail() {
        let thumbURL = entry.url.appendingPathComponent(Project.thumbnailFilename)
        if let data = try? Data(contentsOf: thumbURL),
           let image = NSImage(data: data) {
            thumbnail = image
        }
    }
}
