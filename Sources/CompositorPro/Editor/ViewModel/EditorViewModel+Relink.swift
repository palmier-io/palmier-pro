import Foundation

// Reconnect offline media by repointing assets at a relocated source file or folder.
extension EditorViewModel {

    /// Outcome of a folder relink request. `nil` from the request means it was cancelled or
    /// superseded, so no toast should be shown.
    struct RelinkResult: Sendable, Equatable {
        let relinked: Int
        let total: Int
    }

    /// Scans a folder for same-named files. Runs on a filesystem worker, never the main actor.
    typealias RelinkScanner = @Sendable (_ folder: URL, _ names: Set<String>) async throws -> [String: URL]

    /// Repoint a single asset at a new source file, re-validate, and rebuild.
    func relinkAsset(id: String, to newURL: URL) {
        guard let asset = mediaAssets.first(where: { $0.id == id }) else { return }
        if let newType = ClipType(fileExtension: newURL.pathExtension.lowercased()), newType != asset.type {
            mediaPanelToast = MediaPanelToast(message: L10n.string("Can't relink \"\(newURL.lastPathComponent)\". Required media type: \(asset.type.localizedTrackLabel). Selected media type: \(newType.localizedTrackLabel)."))
            return
        }
        applyRelink(id: id, to: newURL)
        notifyTimelineChanged()
    }

    /// Match every offline asset to a same-named file under `folder` (recursive) and relink it.
    /// The recursive scan runs off-main and stops as soon as every requested name is resolved;
    /// a newer request or `cancelRelinkScan()` cancels it without touching project state.
    @discardableResult
    func relinkOfflineAssets(
        fromFolder folder: URL,
        scan: @escaping RelinkScanner = { try EditorViewModel.indexFiles(in: $0, matching: $1) }
    ) async -> RelinkResult? {
        relinkScanTask?.cancel()
        let request = makeRelinkRequest()
        guard !request.assets.isEmpty else {
            cancelRelinkScan()
            return RelinkResult(relinked: 0, total: 0)
        }

        let token = UUID()
        relinkRequestToken = token
        let names = Set(request.assets.map(\.name))
        let scanTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await scan(folder, names)
        }
        relinkScanTask = scanTask
        defer {
            if relinkRequestToken == token {
                relinkScanTask = nil
                relinkRequestToken = nil
            }
        }

        let index: [String: URL]
        do {
            index = try await scanTask.value
        } catch {
            return nil
        }
        guard relinkRequestToken == token, !Task.isCancelled else { return nil }
        do {
            return try await applyRelinkMatches(index, request: request)
        } catch {
            return nil
        }
    }

    /// Cancels an in-flight folder relink scan. Its results are discarded.
    func cancelRelinkScan() {
        relinkScanTask?.cancel()
        relinkScanTask = nil
        relinkRequestToken = nil
    }

    // MARK: - Request plumbing

    private struct RelinkRequest: Sendable {
        struct Target: Sendable {
            let id: String
            let name: String
            let url: URL
        }

        let projectId: String?
        let projectURL: URL?
        let timelineId: String
        let assets: [Target]
    }

    @MainActor
    private func makeRelinkRequest() -> RelinkRequest {
        let targets = mediaAssets
            .filter { isMediaOffline($0.id) }
            .map { RelinkRequest.Target(id: $0.id, name: $0.url.lastPathComponent.lowercased(), url: $0.url) }
        return RelinkRequest(
            projectId: projectId,
            projectURL: projectURL,
            timelineId: activeTimelineId,
            assets: targets.sorted { $0.id < $1.id }
        )
    }

    /// Publishes matches under one package intent after revalidating the request identity.
    @MainActor
    private func applyRelinkMatches(_ index: [String: URL], request: RelinkRequest) async throws -> RelinkResult? {
        try await projectPackageCoordinator.withIntent { lease in
            try Task.checkCancellation()
            guard !projectPackageCoordinator.isClosed,
                  request.projectId == projectId,
                  request.projectURL == projectURL,
                  request.timelineId == activeTimelineId else { throw CancellationError() }
            var relinked = 0
            for target in request.assets {
                guard isMediaOffline(target.id),
                      mediaAssets.first(where: { $0.id == target.id })?.url == target.url,
                      let match = index[target.name] else { continue }
                applyRelink(id: target.id, to: match)
                relinked += 1
            }
            if relinked > 0 { notifyTimelineChanged() }
            try projectPackageCoordinator.validate(lease)
            return RelinkResult(relinked: relinked, total: request.assets.count)
        }
    }

    private func applyRelink(id: String, to newURL: URL) {
        guard let i = mediaAssets.firstIndex(where: { $0.id == id }) else { return }
        mediaAssets[i].url = newURL
        mediaAssets[i].importInput = MediaImportInput(sourcePath: newURL.path, createdAt: Date())
        denoiseFailed.remove(id)
        mediaVisualCache.invalidate(id)
        speakerAssignments.removeValue(forKey: id)
        if let j = mediaManifest.entries.firstIndex(where: { $0.id == id }) {
            mediaManifest.entries[j].source = mediaAssets[i].toManifestEntry(projectURL: projectURL).source
        }
        let asset = mediaAssets[i]
        updateManifestMetadata(for: [asset])
        Task { await finalizeImportedAsset(asset) }
    }

    /// Lowercased filename → URL for requested regular files under `folder`, first match wins.
    /// Runs off-main; stops once every requested name is found.
    nonisolated static func indexFiles(in folder: URL, matching names: Set<String>) throws -> [String: URL] {
        var index: [String: URL] = [:]
        var remaining = names
        guard !remaining.isEmpty else { return index }
        let keys: Set<URLResourceKey> = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys)) else {
            return index
        }
        for case let url as URL in walker {
            try Task.checkCancellation()
            let key = url.lastPathComponent.lowercased()
            guard remaining.contains(key) else { continue }
            guard (try? url.resourceValues(forKeys: keys))?.isRegularFile == true else { continue }
            index[key] = url
            remaining.remove(key)
            if remaining.isEmpty { break }
        }
        return index
    }
}
