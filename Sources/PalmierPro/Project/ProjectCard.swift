import SwiftUI

struct ProjectCard: View {
    let entry: ProjectEntry
    let onOpen: (URL) -> Void
    let onRemove: (URL) -> Void

    @State private var isHovered = false
    @State private var thumbnail: NSImage?
    @State private var showDeleteConfirmation = false

    private let cardRadius: CGFloat = AppTheme.Radius.mdLg

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // Thumbnail
            AppTheme.Background.placeholderColor
                .aspectRatio(5.0/4.0, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: AppTheme.FontSize.title2, weight: .light))
                            .foregroundStyle(AppTheme.Text.mutedColor)
                    }
                }
                .overlay {
                    if !entry.isAccessible {
                        Color.black.opacity(0.6)

                        VStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: "questionmark.folder")
                                .font(.system(size: AppTheme.FontSize.title1))
                            Text("Not Found")
                                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        }
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    }
                }
                .clipped()
                .onTapGesture {
                    if entry.isAccessible { onOpen(entry.url) }
                }

            // Bottom gradient + label overlay
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.7), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 60)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(entry.name)
                    .font(.system(size: AppTheme.FontSize.sm, weight: .medium))
                    .foregroundStyle(entry.isAccessible ? .white : AppTheme.Text.mutedColor)
                    .lineLimit(1)

                Text(Self.relativeString(for: entry.createdDate))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(.white.opacity(AppTheme.Opacity.medium))
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.bottom, AppTheme.Spacing.smMd)
        }
        .opacity(entry.isAccessible ? 1.0 : 0.6)
        .overlay(alignment: .topTrailing) {
            if isHovered {
                Button { showDeleteConfirmation = true } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: AppTheme.FontSize.smMd, weight: .semibold))
                        .foregroundStyle(.red)
                        .frame(width: AppTheme.IconSize.lgXl, height: AppTheme.IconSize.lgXl)
                        .glassEffect(.regular, in: .circle)
                }
                .buttonStyle(.plain)
                .padding(AppTheme.Spacing.smMd)
                .transition(.opacity.combined(with: .scale))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cardRadius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(isHovered ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                    lineWidth: AppTheme.BorderWidth.hairline
                )
        )
        .shadow(color: .black.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 12 : 4, y: isHovered ? 4 : 2)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .padding(AppTheme.Spacing.xs)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
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
            Button("Delete Project", role: .destructive) { showDeleteConfirmation = true }
        }
        .alert("Delete \"\(entry.name)\"?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                try? ProjectRegistry.shared.delete(entry.url)
            }
        } message: {
            Text("The project will be moved to the Trash.")
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
