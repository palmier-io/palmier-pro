import Foundation

extension ToolExecutor {
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
        let name = try args.requireString("name")
        let parent: String? = try {
            guard let id = args.string("parentFolderId") else { return nil }
            guard editor.folder(id: id) != nil else {
                throw ToolError("parentFolderId not found: \(id)")
            }
            return id
        }()
        let id = editor.createFolder(name: name, in: parent)
        return .ok(Self.jsonString(["id": id, "name": name]) ?? "{}")
    }

    func moveToFolder(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let assetIds = args.stringArray("assetIds")
        guard !assetIds.isEmpty else { throw ToolError("assetIds is required") }
        for id in assetIds {
            guard editor.mediaAssets.contains(where: { $0.id == id }) else {
                throw ToolError("Media asset not found: \(id)")
            }
        }
        let folderId = try resolveFolderId(args, editor: editor)
        editor.moveAssetsToFolder(assetIds: Set(assetIds), folderId: folderId)
        return .ok("Moved \(assetIds.count) asset(s)\(folderId.map { " to folder \($0)" } ?? " to root")")
    }
}
