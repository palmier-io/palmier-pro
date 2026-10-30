import Foundation

// Folders use paths ("Hero shots/Takes"), not ids. Paths resolve case-insensitively; creating missing segments.
extension ToolExecutor {

    // MARK: - Folder path helpers (shared by organize_media, get_media, import, generate)

    func folderPathString(_ folderId: String?, editor: EditorViewModel) -> String? {
        guard let folderId else { return nil }
        let path = editor.folderPath(for: folderId)
        return path.isEmpty ? nil : path.map(\.name).joined(separator: "/")
    }

    func allFolderPaths(_ editor: EditorViewModel) -> [String] {
        editor.folders
            .compactMap { folderPathString($0.id, editor: editor) }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Strict resolve; throws with the current folder list when the path doesn't match.
    func folderId(atPath path: String, editor: EditorViewModel) throws -> String {
        guard let id = try resolveFolderSegments(path, editor: editor) else {
            throw ToolError("Folder not found: '\(path)'. Folders: \(folderListForError(editor))")
        }
        return id
    }

    /// Resolves path, creating missing folders. Returns id and created paths.
    func resolveOrCreateFolder(path: String, editor: EditorViewModel) throws -> (id: String, created: [String]) {
        let segments = try folderSegments(path)
        var parent: String?
        var walked: [String] = []
        var created: [String] = []
        for segment in segments {
            walked.append(segment)
            if let existing = try childFolder(named: segment, under: parent, editor: editor, path: path) {
                parent = existing
            } else {
                parent = editor.createFolder(name: segment, in: parent)
                created.append(walked.joined(separator: "/"))
            }
        }
        return (parent!, created)
    }

    /// Gets 'folder' arg as a path, creating as needed. Defaults to last reference asset's folder.
    func resolveFolder(
        _ args: [String: Any], editor: EditorViewModel, fallbackReferences: [MediaAsset] = []
    ) throws -> String? {
        if let path = args.string("folder") {
            return try resolveOrCreateFolder(path: path, editor: editor).id
        }
        return fallbackReferences.last?.folderId
    }

    private func resolveFolderSegments(_ path: String, editor: EditorViewModel) throws -> String? {
        var parent: String?
        for segment in try folderSegments(path) {
            guard let next = try childFolder(named: segment, under: parent, editor: editor, path: path) else {
                return nil
            }
            parent = next
        }
        return parent
    }

    private func folderSegments(_ path: String) throws -> [String] {
        let segments = path.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty }) else {
            throw ToolError("Invalid folder path '\(path)'. Use segment names joined by '/', e.g. 'B-roll/Sunset'.")
        }
        return segments
    }

    private func childFolder(
        named name: String, under parent: String?, editor: EditorViewModel, path: String
    ) throws -> String? {
        let matches = editor.folders.filter {
            $0.parentFolderId == parent && $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }
        if matches.count > 1 {
            if let exact = matches.first(where: { $0.name == name }) { return exact.id }
            throw ToolError("Folder path '\(path)' is ambiguous at '\(name)' (\(matches.count) matches). Rename one of the duplicates first.")
        }
        return matches.first?.id
    }

    private func folderListForError(_ editor: EditorViewModel) -> String {
        let paths = allFolderPaths(editor)
        return paths.isEmpty ? "(none yet)" : paths.joined(separator: ", ")
    }

    // MARK: - organize_media

    private enum LibraryItem {
        case asset(String)
        case timeline(String)
        case folder(id: String, path: String)
    }

    private struct OrganizeMove {
        let items: [LibraryItem]
        let intoPath: String?
    }

    private struct OrganizeRename {
        let item: LibraryItem
        let name: String
    }

    func organizeMedia(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["createFolders", "moves", "renames", "deletes"], path: "organize_media")

        let createPaths = args.stringArray("createFolders")
        let moves = try parseMoves(args, editor: editor)
        let renames = try parseRenames(args, editor: editor)
        let deletes = try args.stringArray("deletes").map {
            try libraryItem($0, editor: editor, path: "deletes")
        }
        guard !createPaths.isEmpty || !moves.isEmpty || !renames.isEmpty || !deletes.isEmpty else {
            throw ToolError("Nothing to do — pass at least one of createFolders, moves, renames, deletes.")
        }

        var assetIds = Set<String>(), timelineIds = Set<String>(), folderIds = Set<String>()
        for item in deletes {
            switch item {
            case .asset(let id): assetIds.insert(id)
            case .timeline(let id): timelineIds.insert(id)
            case .folder(let id, _): folderIds.insert(id)
            }
        }
        guard timelineIds.count < editor.timelines.count else {
            throw ToolError("Can't delete every timeline — the project needs at least one.")
        }
        // Validate every folder path (syntax + ambiguity) before mutating anything.
        for path in createPaths + moves.compactMap(\.intoPath) {
            _ = try resolveFolderSegments(path, editor: editor)
        }

        var createdFolders: [String] = []
        var movedCount = 0
        var clipsRemoved = 0
        var warnings: [String] = []
        let snapshot = timelineSnapshot(editor)
        let activeBefore = editor.activeTimelineId

        try editor.undo.perform("Organize Media") {
            for path in createPaths {
                createdFolders += try resolveOrCreateFolder(path: path, editor: editor).created
            }

            for move in moves {
                var destination: String?
                if let intoPath = move.intoPath {
                    let resolved = try resolveOrCreateFolder(path: intoPath, editor: editor)
                    destination = resolved.id
                    createdFolders += resolved.created
                }
                var assets: Set<String> = [], timelines: Set<String> = [], folders: Set<String> = []
                for item in move.items {
                    switch item {
                    case .asset(let id): assets.insert(id)
                    case .timeline(let id): timelines.insert(id)
                    case .folder(let id, _): folders.insert(id)
                    }
                }
                editor.moveAssetsToFolder(assetIds: assets, folderId: destination)
                editor.moveTimelinesToFolder(timelineIds: timelines, folderId: destination)
                editor.moveFoldersToFolder(folderIds: folders, parentFolderId: destination)
                movedCount += move.items.count
            }

            for rename in renames {
                switch rename.item {
                case .asset(let id): editor.renameMediaAsset(id: id, name: rename.name)
                case .timeline(let id): editor.renameTimeline(id, to: rename.name)
                case .folder(let id, _): editor.renameFolder(id: id, name: rename.name)
                }
            }

            // Assets and folders first so the clip-count diff excludes deleted timelines' own clips.
            let clipsBefore = totalClipCount(editor)
            if !assetIds.isEmpty { editor.deleteMediaAssets(ids: assetIds) }
            if !folderIds.isEmpty { editor.deleteFolders(ids: folderIds) }
            clipsRemoved = clipsBefore - totalClipCount(editor)
            for id in timelineIds { editor.deleteTimeline(id) }
        }

        if !timelineIds.isEmpty {
            let nestRefs = editor.timelines.flatMap(\.tracks).flatMap(\.clips)
                .filter { timelineIds.contains($0.mediaRef) }.count
            if nestRefs > 0 {
                warnings.append("\(nestRefs) nest clip(s) still reference deleted timeline(s) and will render black.")
            }
        }

        var payload: [String: Any] = [:]
        if !createdFolders.isEmpty { payload["createdFolders"] = createdFolders }
        if movedCount > 0 { payload["moved"] = movedCount }
        if !renames.isEmpty { payload["renamed"] = renames.count }
        if !deletes.isEmpty {
            var deleted: [String: Any] = [:]
            if !assetIds.isEmpty { deleted["assets"] = assetIds.count }
            if !folderIds.isEmpty { deleted["folders"] = folderIds.count }
            if !timelineIds.isEmpty { deleted["timelines"] = timelineIds.count }
            payload["deleted"] = deleted
        }
        if clipsRemoved > 0 { payload["clipsRemoved"] = clipsRemoved }
        if !warnings.isEmpty { payload["warnings"] = warnings }
        if editor.activeTimelineId != activeBefore {
            payload["notes"] = ["Active timeline changed — re-read get_timeline."]
            return .ok(Self.jsonString(payload) ?? "{}")
        }
        return mutationResult(editor, since: snapshot, extra: payload)
    }

    private func parseMoves(_ args: [String: Any], editor: EditorViewModel) throws -> [OrganizeMove] {
        guard let entries = try organizeEntries(args, key: "moves") else { return [] }
        return try entries.enumerated().map { idx, entry in
            let path = "moves[\(idx)]"
            try validateUnknownKeys(entry, allowed: ["items", "into"], path: path)
            let refs = entry.stringArray("items")
            guard !refs.isEmpty else { throw ToolError("\(path): items is required") }
            let items = try refs.map { try libraryItem($0, editor: editor, path: path) }
            let intoPath = entry.string("into")
            // Cycle check by path, at parse time — before any folder gets created.
            if let intoPath {
                let intoSegments = try folderSegments(intoPath).map { $0.lowercased() }
                for case .folder(let id, let itemPath) in items {
                    let currentSegments = (folderPathString(id, editor: editor) ?? itemPath)
                        .split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    if intoSegments.starts(with: currentSegments) {
                        throw ToolError("Can't move folder '\(itemPath)' into itself or its own subfolder.")
                    }
                }
            }
            return OrganizeMove(items: items, intoPath: intoPath)
        }
    }

    private func parseRenames(_ args: [String: Any], editor: EditorViewModel) throws -> [OrganizeRename] {
        guard let entries = try organizeEntries(args, key: "renames") else { return [] }
        return try entries.enumerated().map { idx, entry in
            let path = "renames[\(idx)]"
            try validateUnknownKeys(entry, allowed: ["item", "name"], path: path)
            let ref = try entry.requireString("item")
            let name = try entry.requireString("name")
            return OrganizeRename(item: try libraryItem(ref, editor: editor, path: path), name: name)
        }
    }

    private func organizeEntries(_ args: [String: Any], key: String) throws -> [[String: Any]]? {
        guard let raw = args[key] else { return nil }
        guard let entries = raw as? [Any], !entries.isEmpty else {
            throw ToolError("'\(key)' must be a non-empty array")
        }
        return try entries.enumerated().map { idx, raw in
            guard let entry = raw as? [String: Any] else {
                throw ToolError("\(key)[\(idx)] must be an object")
            }
            return entry
        }
    }

    private func libraryItem(_ ref: String, editor: EditorViewModel, path: String) throws -> LibraryItem {
        if editor.mediaAssets.contains(where: { $0.id == ref }) { return .asset(ref) }
        if editor.timeline(for: ref) != nil { return .timeline(ref) }
        if let id = try? resolveFolderSegments(ref, editor: editor) {
            return .folder(id: id, path: ref)
        }
        throw ToolError("\(path): '\(ref)' is not an asset id, timeline id, or folder path. Folders: \(folderListForError(editor))")
    }

    private func totalClipCount(_ editor: EditorViewModel) -> Int {
        editor.timelines.reduce(0) { sum, t in sum + t.tracks.reduce(0) { $0 + $1.clips.count } }
    }
}
