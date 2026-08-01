import SwiftUI

private func abbreviatingHome(_ url: URL) -> String {
    url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

struct StoragePane: View {
    @State private var cacheBytes: Int64 = 0
    @State private var isClearing = false
    @State private var indexBytes: Int64 = 0
    @State private var modelBytes: Int64 = 0
    @State private var searchEnabled = SearchIndexConfig.enabled
    @State private var scratchRoot = StorageLocations.configuredScratchRoot
    @State private var projectsRoot = StorageLocations.configuredProjectsRoot
    @State private var unavailable: [StorageLocationKind] = []

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xxl) {
            SettingsSection(title: L10n.string("Locations")) {
                locationsSection
            }
            SettingsSection(title: L10n.string("Cache")) {
                cacheRow
            }
            SettingsSection(title: L10n.string("Search")) {
                searchIndexSection
            }
        }
        .task(id: [scratchRoot?.path, projectsRoot?.path]) { await refresh() }
    }

    private var locationsSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.md) {
            StorageLocationRow(
                title: StorageLocationKind.scratch.localizedTitle,
                detail: L10n.string("Render previews, waveforms, thumbnails, transcripts, staged media, and downloaded models. Put this on a fast drive."),
                root: $scratchRoot,
                defaultPath: L10n.string("\(abbreviatingHome(StorageLocations.defaultCachesDirectory)) and $TMPDIR"),
                save: { StorageLocations.configuredScratchRoot = $0 }
            )
            StorageLocationRow(
                title: StorageLocationKind.projects.localizedTitle,
                detail: L10n.string("Where new projects are created. Existing projects stay where they are."),
                root: $projectsRoot,
                defaultPath: abbreviatingHome(StorageLocations.defaultProjectsDirectory),
                save: { StorageLocations.configuredProjectsRoot = $0 }
            )
            ForEach(locationMessages, id: \.self) { message in
                Text(message)
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var status: StorageLocationStatus {
        .init(scratchRoot: scratchRoot, projectsRoot: projectsRoot, unavailable: unavailable)
    }

    private var locationMessages: [String] {
        var messages = status.unavailable.map {
            L10n.string("\($0.localizedTitle) unavailable. Using the default location until the folder is back.")
        }
        if status.needsRelaunch {
            messages.append(L10n.string("Relaunch Palmier Pro to use the new locations. Cached files and downloaded models at the previous location are removed."))
        }
        return messages
    }

    private var cacheRow: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(L10n.string("Temporary files"))
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(L10n.string("Playback previews, waveforms, filmstrip thumbnails, and transcripts. Safe to clear; files rebuild as needed."))
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

            Button(L10n.string("Clear cache")) {
                clear()
            }
            .buttonStyle(actionButtonStyle)
            .disabled(isClearing || cacheBytes == 0)
        }
    }

    private var searchIndexSection: some View {
        VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
            HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                    Text(L10n.string("Media indexing"))
                        .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                        .foregroundStyle(AppTheme.Text.primaryColor)
                    Text(L10n.string("Indexes imported media for on-device search."))
                        .font(.system(size: AppTheme.FontSize.sm))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AppTheme.Spacing.lg)
                Toggle(String(), isOn: $searchEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel(L10n.string("Media search"))
                    .onChange(of: searchEnabled) { _, newValue in
                        VisualModelLoader.shared.setEnabled(newValue)
                    }
            }

            HStack(spacing: AppTheme.Spacing.sm) {
                Text(L10n.string("Index"))
                    .font(.system(size: AppTheme.FontSize.xs))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                Text(ByteCountFormatter.string(fromByteCount: indexBytes, countStyle: .file))
                    .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                    .foregroundStyle(AppTheme.Text.secondaryColor)
                Spacer(minLength: AppTheme.Spacing.md)
                Button(L10n.string("Clear index")) { clearIndex() }
                    .buttonStyle(actionButtonStyle)
                    .disabled(indexBytes == 0)
            }
            .padding(.top, AppTheme.Spacing.xs)

            if modelBytes > 0 {
                HStack(spacing: AppTheme.Spacing.sm) {
                    Text(L10n.string("Model"))
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Text.tertiaryColor)
                    Text(verbatim: "\(SearchIndexConfig.manifest.model) · \(ByteCountFormatter.string(fromByteCount: modelBytes, countStyle: .file))")
                        .font(.system(size: AppTheme.FontSize.xs).monospacedDigit())
                        .foregroundStyle(AppTheme.Text.secondaryColor)
                    Spacer(minLength: AppTheme.Spacing.md)
                    Button(L10n.string("Remove model")) { removeModel() }
                        .buttonStyle(actionButtonStyle)
                }
            }
        }
    }

    private var actionButtonStyle: CapsuleButtonStyle {
        .init(
            variant: .secondary,
            size: .small,
            fill: AnyShapeStyle(AppTheme.Background.raisedColor)
        )
    }

    private nonisolated static let caches = [ImageVideoGenerator.cache, MediaVisualCache.diskCache, DiskCache(directory: TranscriptCache.directory), AudioEnhancer.cache, VoiceActivity.cache, SpeakerIdentity.cache]

    private var displayPath: String { abbreviatingHome(DiskCache.rootDirectory) }

    private var formattedSize: String {
        if isClearing { return L10n.string("Clearing…") }
        return ByteCountFormatter.string(fromByteCount: cacheBytes, countStyle: .file)
    }

    private func clear() {
        isClearing = true
        Task.detached {
            for cache in Self.caches { cache.clear() }
            await TranscriptCache.shared.clearMemory()
            await MainActor.run {
                isClearing = false
                for document in NSDocumentController.shared.documents {
                    (document as? VideoProject)?.editorViewModel.resetAnalysisSessionState()
                }
            }
            await refresh()
        }
    }

    private func clearIndex() {
        Task {
            await SearchIndexCoordinator.clearIndexGlobally()
            await refresh()
        }
    }

    private func removeModel() {
        Task {
            await VisualModelLoader.shared.remove()
            await refresh()
        }
    }

    private func refresh() async {
        let scratch = scratchRoot
        let projects = projectsRoot
        let stats = await Task.detached {
            (
                cache: Self.caches.reduce(0) { $0 + $1.size() },
                index: DiskCache.bytes(at: EmbeddingStore.directory),
                model: DiskCache.bytes(at: ModelDownloader.modelsDir),
                unavailable: StorageLocationStatus.unavailableKinds(
                    scratchRoot: scratch,
                    projectsRoot: projects
                )
            )
        }.value
        cacheBytes = stats.cache
        indexBytes = stats.index
        modelBytes = stats.model
        unavailable = stats.unavailable
    }
}

private struct StorageLocationRow: View {
    let title: String
    let detail: String
    @Binding var root: URL?
    let defaultPath: String
    let save: (URL?) -> Void

    @State private var rejection: String?

    var body: some View {
        HStack(alignment: .top, spacing: AppTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: AppTheme.Spacing.xs) {
                Text(title)
                    .font(.system(size: AppTheme.FontSize.md, weight: AppTheme.FontWeight.regular))
                    .foregroundStyle(AppTheme.Text.primaryColor)
                Text(detail)
                    .font(.system(size: AppTheme.FontSize.sm))
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                Text(root.map(abbreviatingHome) ?? defaultPath)
                    .font(.system(size: AppTheme.FontSize.xs).monospaced())
                    .foregroundStyle(AppTheme.Text.tertiaryColor)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, AppTheme.Spacing.xs)
                if let rejection {
                    Text(rejection)
                        .font(.system(size: AppTheme.FontSize.xs))
                        .foregroundStyle(AppTheme.Status.warningColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: AppTheme.Spacing.lg)

            HStack(spacing: AppTheme.Spacing.sm) {
                if root != nil {
                    Button(L10n.string("Use Default")) { set(nil) }
                        .buttonStyle(buttonStyle)
                }
                Button(L10n.string("Choose…")) { choose() }
                    .buttonStyle(buttonStyle)
            }
        }
    }

    private var buttonStyle: CapsuleButtonStyle {
        .init(variant: .secondary, size: .small, fill: AnyShapeStyle(AppTheme.Background.raisedColor))
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = L10n.string("Choose")
        panel.title = title
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await adopt(url) }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    /// Confirms the folder accepts writes before storing it, so a read-only or offline pick is
    /// refused here rather than silently falling back to the default on the next launch.
    private func adopt(_ url: URL) async {
        let usable = await Task.detached { StorageLocations.usableDirectory(at: url) != nil }.value
        guard usable else {
            rejection = L10n.string("Can't write to that folder. Choose another.")
            return
        }
        set(url)
    }

    private func set(_ url: URL?) {
        rejection = nil
        root = url
        save(url)
    }
}
