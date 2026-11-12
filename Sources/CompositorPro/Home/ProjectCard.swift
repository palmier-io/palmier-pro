import SwiftUI

struct ProjectCard: View {
    let entry: ProjectEntry
    let isSelecting: Bool
    let isSelected: Bool
    let onOpen: (URL) -> Void
    let onRemove: (URL) -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var thumbnail: NSImage?
    @State private var accessibility: ProjectAccessibility?
    @State private var accessibilityRequest: AccessibilityRequest?

    private enum ProjectAction: Hashable {
        case open
        case reveal
    }

    private struct AccessibilityRequest: Hashable {
        let key: ProjectAccessibility.Key
        let action: ProjectAction?
        let windowIdentity: ObjectIdentifier?
        let id = UUID()
    }

    private var currentAccessibility: ProjectAccessibility? {
        guard accessibility?.key == ProjectAccessibility.Key(entry) else { return nil }
        return accessibility
    }

    private var isAccessible: Bool { currentAccessibility?.isAccessible == true }
    private var isUnavailable: Bool {
        guard let currentAccessibility else { return false }
        return !currentAccessibility.isAccessible
    }

    private var unavailableMessage: String {
        if currentAccessibility?.state == .missing { return L10n.string("File missing") }
        return L10n.string("Can't read \"\(entry.name)\" — it may be missing or you may not have permission.")
    }

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
                    if isUnavailable {
                        AppTheme.MediaOverlay.backgroundColor.opacity(0.6)

                        VStack(spacing: AppTheme.Spacing.xs) {
                            Image(systemName: "questionmark.folder")
                                .font(.system(size: AppTheme.FontSize.title1))
                            Text(verbatim: unavailableMessage)
                                .font(.system(size: AppTheme.FontSize.xs, weight: .medium))
                        }
                        .foregroundStyle(AppTheme.MediaOverlay.tertiaryColor)
                    }
                }
                .clipped()

            // Bottom gradient + label overlay
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: AppTheme.MediaOverlay.backgroundColor.opacity(AppTheme.Opacity.high), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 60)
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: AppTheme.Spacing.xxs) {
                Text(entry.name)
                    .font(.system(size: AppTheme.FontSize.smMd, weight: .regular))
                    .foregroundStyle(isUnavailable
                        ? AppTheme.MediaOverlay.mutedColor
                        : AppTheme.MediaOverlay.primaryColor)
                    .lineLimit(1)

                Text(Self.relativeString(for: entry.createdDate))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.MediaOverlay.primaryColor.opacity(AppTheme.Opacity.medium))
            }
            .padding(.horizontal, AppTheme.Spacing.md)
            .padding(.bottom, AppTheme.Spacing.smMd)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                onSelect()
            } else {
                refreshAccessibility(action: .open)
            }
        }
        .opacity(isUnavailable ? AppTheme.Opacity.strong : AppTheme.Opacity.opaque)
        .overlay(alignment: .topTrailing) {
            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: AppTheme.FontSize.xl, weight: .semibold))
                    .foregroundStyle(isSelected
                        ? AppTheme.MediaOverlay.primaryColor
                        : AppTheme.MediaOverlay.tertiaryColor)
                    .padding(AppTheme.Spacing.smMd)
                    .allowsHitTesting(false)
            } else if isHovered {
                Button(action: onDelete) {
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
                    isSelected
                        ? AppTheme.Accent.primary
                        : AppTheme.Interaction.fill(isHovered ? AppTheme.Opacity.muted : AppTheme.Opacity.hint),
                    lineWidth: isSelected ? AppTheme.BorderWidth.thick : AppTheme.BorderWidth.hairline
                )
        )
        .shadow(color: AppTheme.MediaOverlay.backgroundColor.opacity(isHovered ? 0.4 : 0.2), radius: isHovered ? 12 : 4, y: isHovered ? 4 : 2)
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .padding(AppTheme.Spacing.xs)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
        .contextMenu {
            if isAccessible {
                Button(L10n.string("Open")) { refreshAccessibility(action: .open) }
                Button(L10n.string("Reveal in Finder")) { refreshAccessibility(action: .reveal) }
                Divider()
            }
            Button(L10n.string("Remove from Recents")) { onRemove(entry.url) }
            Button(L10n.string("Delete Project"), role: .destructive, action: onDelete)
        }
        .onAppear { refreshAccessibility() }
        .onChange(of: ProjectAccessibility.Key(entry)) { _, _ in refreshAccessibility() }
        .onChange(of: entry.lastOpenedDate) { _, _ in refreshAccessibility() }
        .onChange(of: isSelecting) { _, _ in
            if accessibilityRequest?.action != nil { refreshAccessibility() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification).receive(on: RunLoop.main)) { _ in
            refreshAccessibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification).receive(on: RunLoop.main)) { _ in
            accessibilityRequest = nil
            accessibility = nil
        }
        .onDisappear {
            accessibilityRequest = nil
            accessibility = nil
        }
        .task(id: accessibilityRequest) {
            guard let request = accessibilityRequest else { return }
            await checkAccessibility(request)
        }
        .task(id: entry.lastOpenedDate) { await loadThumbnail(for: entry.url) }
    }

    private func refreshAccessibility(action: ProjectAction? = nil) {
        accessibility = nil
        guard NSApplication.shared.isActive else {
            accessibilityRequest = nil
            return
        }
        accessibilityRequest = AccessibilityRequest(
            key: ProjectAccessibility.Key(entry), action: action,
            windowIdentity: NSApplication.shared.keyWindow.map(ObjectIdentifier.init)
        )
    }

    private func checkAccessibility(_ request: AccessibilityRequest) async {
        do {
            let results = try await ProjectAccessibility.check([request.key])
            guard !Task.isCancelled, NSApplication.shared.isActive, accessibilityRequest == request,
                  let result = results.first, result.key == request.key,
                  ProjectRegistry.shared.entries.contains(where: { ProjectAccessibility.Key($0) == request.key }) else { return }
            accessibility = result
            guard result.isAccessible, let action = request.action,
                  NSApplication.shared.keyWindow.map(ObjectIdentifier.init) == request.windowIdentity else { return }
            switch action {
            case .open:
                onOpen(request.key.url)
            case .reveal:
                NSWorkspace.shared.selectFile(
                    request.key.url.path,
                    inFileViewerRootedAtPath: request.key.url.deletingLastPathComponent().path
                )
            }
        } catch {
            guard !Task.isCancelled, accessibilityRequest == request else { return }
            accessibility = ProjectAccessibility(key: request.key, state: .unavailable)
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static func relativeString(for date: Date) -> String {
        relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func loadThumbnail(for projectURL: URL) async {
        thumbnail = nil
        let image = await Task.detached(priority: .utility) {
            let thumbURL = projectURL.appendingPathComponent(Project.thumbnailFilename, isDirectory: false)
            return ImageEncoder.thumbnail(url: thumbURL, maxPixelSize: 640)
        }.value
        guard let image, !Task.isCancelled else { return }
        thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
