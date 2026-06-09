import Foundation

fileprivate struct CreateFolderSpec {
    let name: String
    let parentFolderId: String?
}

fileprivate struct MoveToFolderSpec {
    let assetIds: [String]
    let folderId: String?
}

fileprivate struct RenameMediaSpec {
    let mediaRef: String
    let name: String
}

fileprivate struct RenameFolderSpec {
    let folderId: String
    let name: String
}

extension ToolExecutor {
    private static let createFolderEntryAllowedKeys: Set<String> = ["name", "parentFolderId"]
    private static let moveToFolderEntryAllowedKeys: Set<String> = ["assetIds", "folderId"]
    private static let renameMediaEntryAllowedKeys: Set<String> = ["mediaRef", "name"]
    private static let renameFolderEntryAllowedKeys: Set<String> = ["folderId", "name"]

    func listFolders(_ editor: EditorViewModel) -> ToolResult {
        let folders = editor.folders.map { f -> [String: Any] in
            var dict: [String: Any] = ["id": f.id, "name": f.name]
            if let parent = f.parentFolderId { dict["parentFolderId"] = parent }
            return dict
        }
        let body: [String: Any] = ["folders": folders]
        return .ok(Self.jsonString(body) ?? "{}")
    }

    func createFolder(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let (specs, isBatch) = try parseCreateFolderSpecs(args, editor: editor)
        let folders: [[String: Any]] = withUndoGroup(editor, actionName: specs.count == 1 ? "New Folder" : "New Folders") {
            specs.map { spec in
                let id = editor.createFolder(name: spec.name, in: spec.parentFolderId)
                var folder: [String: Any] = ["id": id, "name": spec.name]
                if let parent = spec.parentFolderId { folder["parentFolderId"] = parent }
                return folder
            }
        }
        if !isBatch, let folder = folders.first {
            return .ok(Self.jsonString(folder) ?? "{}")
        }
        return .ok(Self.jsonString(["folders": folders]) ?? "{}")
    }

    func moveToFolder(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let (specs, isBatch) = try parseMoveToFolderSpecs(args, editor: editor)
        if specs.count == 1, let spec = specs.first {
            editor.moveAssetsToFolder(assetIds: Set(spec.assetIds), folderId: spec.folderId)
            return .ok("Moved \(spec.assetIds.count) asset(s)\(spec.folderId.map { " to folder \($0)" } ?? " to root")")
        }

        withUndoGroup(editor, actionName: "Move to Folder") {
            for spec in specs {
                editor.moveAssetsToFolder(assetIds: Set(spec.assetIds), folderId: spec.folderId)
            }
        }
        let assetCount = specs.reduce(0) { $0 + $1.assetIds.count }
        return .ok("Moved \(assetCount) asset(s) across \(isBatch ? specs.count : 1) folder operation(s)")
    }

    func renameMedia(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let (specs, isBatch) = try parseRenameMediaSpecs(args, editor: editor)
        withUndoGroup(editor, actionName: specs.count == 1 ? "Rename Asset" : "Rename Assets") {
            for spec in specs {
                editor.renameMediaAsset(id: spec.mediaRef, name: spec.name)
            }
        }
        if !isBatch, let spec = specs.first {
            return .ok("Renamed \(spec.mediaRef) to '\(spec.name)'")
        }
        return .ok("Renamed \(specs.count) media asset\(specs.count == 1 ? "" : "s")")
    }

    func renameFolder(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let (specs, isBatch) = try parseRenameFolderSpecs(args, editor: editor)
        withUndoGroup(editor, actionName: specs.count == 1 ? "Rename Folder" : "Rename Folders") {
            for spec in specs {
                editor.renameFolder(id: spec.folderId, name: spec.name)
            }
        }
        if !isBatch, let spec = specs.first {
            return .ok("Renamed folder \(spec.folderId) to '\(spec.name)'")
        }
        return .ok("Renamed \(specs.count) folder\(specs.count == 1 ? "" : "s")")
    }

    func deleteMedia(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let assetIds = args.stringArray("assetIds")
        guard !assetIds.isEmpty else { throw ToolError("assetIds is required") }
        for id in assetIds {
            guard editor.mediaAssets.contains(where: { $0.id == id }) else {
                throw ToolError("Media asset not found: \(id)")
            }
        }
        editor.deleteMediaAssets(ids: Set(assetIds))
        return .ok("Deleted \(assetIds.count) asset(s). Any clips referencing them were removed from the timeline.")
    }

    func deleteFolder(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let folderIds = args.stringArray("folderIds")
        guard !folderIds.isEmpty else { throw ToolError("folderIds is required") }
        for id in folderIds {
            guard editor.folder(id: id) != nil else { throw ToolError("folderId not found: \(id)") }
        }
        editor.deleteFolders(ids: Set(folderIds))
        return .ok("Deleted \(folderIds.count) folder(s) with their contents. Any clips referencing deleted assets were removed from the timeline.")
    }

    private func parseCreateFolderSpecs(
        _ args: [String: Any], editor: EditorViewModel
    ) throws -> (specs: [CreateFolderSpec], isBatch: Bool) {
        if let entries = try entryObjects(args, key: "entries") {
            return try (entries.enumerated().map { idx, entry in
                let path = "entries[\(idx)]"
                try validateUnknownKeys(entry, allowed: Self.createFolderEntryAllowedKeys, path: path)
                let name = try entry.requireString("name")
                let parent = try parentFolderId(entry, editor: editor, path: path)
                return CreateFolderSpec(name: name, parentFolderId: parent)
            }, true)
        }
        let name = try args.requireString("name")
        let parent = try parentFolderId(args, editor: editor, path: "create_folder")
        return ([CreateFolderSpec(name: name, parentFolderId: parent)], false)
    }

    private func parseMoveToFolderSpecs(
        _ args: [String: Any], editor: EditorViewModel
    ) throws -> (specs: [MoveToFolderSpec], isBatch: Bool) {
        if let entries = try entryObjects(args, key: "entries") {
            return try (entries.enumerated().map { idx, entry in
                let path = "entries[\(idx)]"
                try validateUnknownKeys(entry, allowed: Self.moveToFolderEntryAllowedKeys, path: path)
                let assetIds = try validAssetIds(entry, editor: editor, path: path)
                let folderId = try resolveFolderId(entry, editor: editor)
                return MoveToFolderSpec(assetIds: assetIds, folderId: folderId)
            }, true)
        }
        let assetIds = try validAssetIds(args, editor: editor, path: "move_to_folder")
        let folderId = try resolveFolderId(args, editor: editor)
        return ([MoveToFolderSpec(assetIds: assetIds, folderId: folderId)], false)
    }

    private func parseRenameMediaSpecs(
        _ args: [String: Any], editor: EditorViewModel
    ) throws -> (specs: [RenameMediaSpec], isBatch: Bool) {
        if let entries = try entryObjects(args, key: "entries") {
            return try (entries.enumerated().map { idx, entry in
                let path = "entries[\(idx)]"
                try validateUnknownKeys(entry, allowed: Self.renameMediaEntryAllowedKeys, path: path)
                let mediaRef = try entry.requireString("mediaRef")
                let name = try entry.requireString("name")
                _ = try asset(mediaRef, editor: editor)
                return RenameMediaSpec(mediaRef: mediaRef, name: name)
            }, true)
        }
        let mediaRef = try args.requireString("mediaRef")
        let name = try args.requireString("name")
        _ = try asset(mediaRef, editor: editor)
        return ([RenameMediaSpec(mediaRef: mediaRef, name: name)], false)
    }

    private func parseRenameFolderSpecs(
        _ args: [String: Any], editor: EditorViewModel
    ) throws -> (specs: [RenameFolderSpec], isBatch: Bool) {
        if let entries = try entryObjects(args, key: "entries") {
            return try (entries.enumerated().map { idx, entry in
                let path = "entries[\(idx)]"
                try validateUnknownKeys(entry, allowed: Self.renameFolderEntryAllowedKeys, path: path)
                let folderId = try entry.requireString("folderId")
                let name = try entry.requireString("name")
                guard editor.folder(id: folderId) != nil else { throw ToolError("\(path): folderId not found: \(folderId)") }
                return RenameFolderSpec(folderId: folderId, name: name)
            }, true)
        }
        let folderId = try args.requireString("folderId")
        let name = try args.requireString("name")
        guard editor.folder(id: folderId) != nil else { throw ToolError("folderId not found: \(folderId)") }
        return ([RenameFolderSpec(folderId: folderId, name: name)], false)
    }

    private func entryObjects(_ args: [String: Any], key: String) throws -> [[String: Any]]? {
        guard let raw = args[key] else { return nil }
        guard let entries = raw as? [Any], !entries.isEmpty else {
            throw ToolError("Missing or empty '\(key)' array")
        }
        return try entries.enumerated().map { idx, raw in
            guard let entry = raw as? [String: Any] else {
                throw ToolError("\(key)[\(idx)] must be an object")
            }
            return entry
        }
    }

    private func parentFolderId(_ args: [String: Any], editor: EditorViewModel, path: String) throws -> String? {
        guard let id = args.string("parentFolderId") else { return nil }
        guard editor.folder(id: id) != nil else {
            throw ToolError("\(path): parentFolderId not found: \(id)")
        }
        return id
    }

    private func validAssetIds(_ args: [String: Any], editor: EditorViewModel, path: String) throws -> [String] {
        let assetIds = args.stringArray("assetIds")
        guard !assetIds.isEmpty else { throw ToolError("\(path): assetIds is required") }
        for id in assetIds {
            guard editor.mediaAssets.contains(where: { $0.id == id }) else {
                throw ToolError("\(path): media asset not found: \(id)")
            }
        }
        return assetIds
    }
}
