import SwiftUI

struct ProjectCard: View {
    @State var url: URL
    let onOpen: (URL) -> Void

    @State private var isHovered = false
    @State private var thumbnail: NSImage?
    @State private var modifiedDate: Date?

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
            }
            .frame(height: 120)
            .clipped()
            .onTapGesture { onOpen(url) }

            VStack(alignment: .leading, spacing: 3) {
                ProjectNameField(url: optionalURLBinding, width: 160)

                if let modifiedDate {
                    Text(Self.relativeString(for: modifiedDate))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
        .background(Color(white: isHovered ? 0.16 : 0.12))
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
            Button("Open") { onOpen(url) }
Button("Reveal in Finder") {
                NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            }
        }
        .task { loadMetadata() }
    }

    private var optionalURLBinding: Binding<URL?> {
        Binding(
            get: { url },
            set: { if let newURL = $0 { url = newURL } }
        )
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static func relativeString(for date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func loadMetadata() {
        let thumbURL = url.appendingPathComponent(Project.thumbnailFilename)
        if let data = try? Data(contentsOf: thumbURL),
           let image = NSImage(data: data) {
            thumbnail = image
        }

        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let date = attrs[.modificationDate] as? Date {
            modifiedDate = date
        }
    }
}
