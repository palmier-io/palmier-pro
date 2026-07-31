import AppKit

enum MediaPanelSelectionMode: Equatable {
    case replacing, toggling, range, extendingRange

    init(modifierFlags: NSEvent.ModifierFlags) {
        let command = modifierFlags.contains(.command)
        let shift = modifierFlags.contains(.shift)
        switch (command, shift) {
        case (true, true): self = .extendingRange
        case (true, false): self = .toggling
        case (false, true): self = .range
        case (false, false): self = .replacing
        }
    }
}

private typealias MediaPanelSelectionSnapshot = (keys: Set<String>, anchor: String?)

extension EditorViewModel {
    enum MediaSelectionDirection {
        case left, right, up, down

        func step(columnCount: Int) -> Int {
            switch self {
            case .left: -1
            case .right: +1
            case .up: -columnCount
            case .down: +columnCount
            }
        }

        var startsFromEnd: Bool { self == .left || self == .up }
    }

    func moveMediaSelection(direction: MediaSelectionDirection) {
        let ordered = mediaPanelOrderedItemIds
        guard !ordered.isEmpty else { return }
        let selectedKeys = mediaPanelSelectedKeys()

        let next: String
        if let anchor = ordered.last(where: { selectedKeys.contains($0) }),
           let index = ordered.firstIndex(of: anchor) {
            let rawIndex = index + direction.step(columnCount: max(1, mediaPanelColumnCount))
            let targetIndex = max(0, min(ordered.count - 1, rawIndex))
            guard targetIndex != index else { return }
            next = ordered[targetIndex]
        } else {
            next = direction.startsFromEnd ? ordered[ordered.count - 1] : ordered[0]
        }

        selectMediaPanelItem(next)
    }

    func selectMediaPanelItem(_ key: String) {
        guard isValidMediaPanelItemKey(key) else { return }
        mediaPanelScrollTarget = key
        selectMediaPanelItem(key, mode: .replacing)
    }

    func selectMediaPanelItem(_ key: String, mode: MediaPanelSelectionMode, atSourceFrame sourceFrame: Int = 0) {
        guard isValidMediaPanelItemKey(key) else { return }
        var selection = mediaPanelSelectedKeys()
        var anchor = mediaPanelSelectionAnchor

        switch mode {
        case .replacing:
            selection = [key]
            anchor = key
        case .toggling:
            if selection.contains(key) {
                selection.remove(key)
            } else {
                selection.insert(key)
            }
            anchor = key
        case .range, .extendingRange:
            if let range = mediaPanelSelectionRange(through: key) {
                if mode == .range {
                    selection = range
                } else {
                    selection.formUnion(range)
                }
            } else {
                selection = [key]
                anchor = key
            }
        }

        applyMediaPanelSelection(selection, anchor: anchor)
        previewMediaPanelAsset(for: key, replacingSelection: mode == .replacing, atSourceFrame: sourceFrame)
    }

    func selectAllMediaPanelItems() {
        let orderedIds = mediaPanelOrderedItemIds
        applyMediaPanelSelection(
            Set(orderedIds),
            anchor: orderedIds.first(where: isValidMediaPanelItemKey)
        )
    }

    func clearMediaPanelSelection() { applyMediaPanelSelection([], anchor: nil) }

    func createMediaPanelFolder(in parentFolderId: String?) -> String {
        let selectionBefore = mediaPanelSelectionSnapshot()
        return undo.perform("New Folder") {
            undo.register("New Folder", withTarget: self) { vm in
                vm.restoreMediaPanelSelection(selectionBefore, actionName: "New Folder")
            }
            let id = createFolder(name: "New Folder", in: parentFolderId)
            selectMediaPanelItem(MediaPanelItemKey.folder(id))
            return id
        }
    }

    func deleteMediaPanelItems(targeting contextKey: String? = nil) {
        if let contextKey, isValidMediaPanelItemKey(contextKey),
           !mediaPanelSelectedKeys().contains(contextKey) {
            applyMediaPanelSelection([contextKey], anchor: contextKey)
        }

        let folderIds = Set(selectedFolderIds.filter { folder(id: $0) != nil })
        let deletedFolderIds = folderIdsIncludingDescendants(folderIds)
        let assetIds = Set(selectedMediaAssetIds.filter { id in
            guard let asset = mediaAssetsById[id] else { return false }
            return asset.folderId.map { !deletedFolderIds.contains($0) } ?? true
        })

        let selectedTimelines = selectedTimelineIds.intersection(Set(timelines.map(\.id)))
        let timelineIds = timelines.filter { selectedTimelines.contains($0.id) }
            .prefix(max(0, timelines.count - 1)).map(\.id)
        if selectedTimelines.count > timelineIds.count {
            mediaPanelToast = MediaPanelToast(message: L10n.string("Can't delete every timeline — the project needs at least one."))
        }

        let itemCount = folderIds.count + assetIds.count + timelineIds.count
        guard itemCount > 0 else { return }
        let actionName = mediaPanelDeleteActionName(
            folderCount: folderIds.count,
            assetCount: assetIds.count,
            timelineCount: timelineIds.count
        )
        let selectionBefore = mediaPanelSelectionSnapshot()

        undo.perform(actionName) {
            undo.register(actionName, withTarget: self) { vm in
                vm.restoreMediaPanelSelection(selectionBefore, actionName: actionName)
            }
            if !folderIds.isEmpty { deleteFolders(ids: folderIds) }
            if !assetIds.isEmpty { deleteMediaAssets(ids: assetIds) }
            for id in timelineIds { deleteTimeline(id) }
        }

        pruneMediaPanelSelectionAnchor()
    }

    func pruneMediaPanelSelectionAnchor() {
        let selection = mediaPanelSelectedKeys()
        guard mediaPanelSelectionAnchor.map(selection.contains) != true else { return }
        mediaPanelSelectionAnchor = mediaPanelOrderedItemIds.first(where: selection.contains)
    }

    func mediaPanelSelectedKeys() -> Set<String> {
        selectedMediaAssetIds
            .union(selectedFolderIds.map(MediaPanelItemKey.folder))
            .union(selectedTimelineIds.map(MediaPanelItemKey.timeline))
    }

    private func mediaPanelSelectionRange(through key: String) -> Set<String>? {
        guard let anchor = mediaPanelSelectionAnchor, isValidMediaPanelItemKey(anchor),
              let anchorIndex = mediaPanelOrderedItemIds.firstIndex(of: anchor),
              let targetIndex = mediaPanelOrderedItemIds.firstIndex(of: key) else { return nil }
        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        return Set(mediaPanelOrderedItemIds[bounds])
    }

    private enum MediaPanelItem {
        case folder(String)
        case timeline(String)
        case asset(String)
    }

    private func mediaPanelItem(for key: String) -> MediaPanelItem? {
        if let folderId = MediaPanelItemKey.folderId(from: key) {
            return folder(id: folderId) != nil ? .folder(folderId) : nil
        }
        if let timelineId = MediaPanelItemKey.timelineId(from: key) {
            return timeline(for: timelineId) != nil ? .timeline(timelineId) : nil
        }
        return mediaAssetsById[key] != nil ? .asset(key) : nil
    }

    private func isValidMediaPanelItemKey(_ key: String) -> Bool { mediaPanelItem(for: key) != nil }

    private func applyMediaPanelSelection(_ keys: Set<String>, anchor: String?) {
        var assetIds: Set<String> = []
        var folderIds: Set<String> = []
        var timelineIds: Set<String> = []

        for key in keys {
            switch mediaPanelItem(for: key) {
            case .folder(let id): folderIds.insert(id)
            case .timeline(let id): timelineIds.insert(id)
            case .asset(let id): assetIds.insert(id)
            case nil: break
            }
        }

        if selectedMediaAssetIds != assetIds { selectedMediaAssetIds = assetIds }
        if selectedFolderIds != folderIds { selectedFolderIds = folderIds }
        if selectedTimelineIds != timelineIds { selectedTimelineIds = timelineIds }
        mediaPanelSelectionAnchor = anchor
    }

    private func previewMediaPanelAsset(for key: String, replacingSelection: Bool, atSourceFrame sourceFrame: Int) {
        guard let asset = mediaAssetsById[key] else { return }
        if replacingSelection {
            selectMediaAsset(asset, atSourceFrame: sourceFrame)
        } else {
            openPreviewTab(for: asset, atSourceFrame: sourceFrame)
        }
    }

    private func mediaPanelSelectionSnapshot() -> MediaPanelSelectionSnapshot {
        (keys: mediaPanelSelectedKeys(), anchor: mediaPanelSelectionAnchor)
    }

    private func restoreMediaPanelSelection(_ snapshot: MediaPanelSelectionSnapshot, actionName: String) {
        let inverse = mediaPanelSelectionSnapshot()
        applyMediaPanelSelection(snapshot.keys, anchor: snapshot.anchor)
        undo.register(actionName, withTarget: self) { vm in
            vm.restoreMediaPanelSelection(inverse, actionName: actionName)
        }
    }

    private func mediaPanelDeleteActionName(folderCount: Int, assetCount: Int, timelineCount: Int) -> String {
        guard folderCount + assetCount + timelineCount == 1 else { return "Delete Media Items" }
        if folderCount == 1 { return "Delete Folder" }
        if timelineCount == 1 { return "Delete Timeline" }
        return "Delete Media"
    }
}
