import AppKit
import Foundation

/// MCP server-only project navigation. Runs on AppState/ProjectRegistry before editor loads.
extension ToolExecutor {

    func manageProject(_ args: [String: Any]) async -> ToolResult {
        do {
            try validateUnknownKeys(
                args,
                allowed: ["action", "name", "id", "path", "fps", "aspectRatio", "quality"],
                path: "manage_project"
            )
            guard let action = args.string("action") else {
                throw ToolError("manage_project requires an 'action'.")
            }
            let actionArgs = args.filter { $0.key != "action" }
            switch action {
            case "list":   return try listProjects(actionArgs)
            case "open":   return try await openProject(actionArgs)
            case "create": return try await createProject(actionArgs)
            case "close":  return try await closeProject(actionArgs)
            default:
                throw ToolError("Unknown project action '\(action)'. Use one of: list, open, create, close.")
            }
        } catch let err as ToolError {
            return .error(err.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func listProjects(_ args: [String: Any]) throws -> ToolResult {
        try validateUnknownKeys(args, allowed: [], path: "manage_project action='list'")
        let openDocs = AppState.shared.openProjects
        let openURLs = Set(openDocs.compactMap { $0.fileURL?.standardizedFileURL })
        let active = sessionProject
        let activeURL = active?.fileURL?.standardizedFileURL
        let visible = frontmostProject
        let visibleURL = visible?.fileURL?.standardizedFileURL

        // Only registered projects, sorted by most recently opened.
        let projects = ProjectRegistry.shared.sortedEntries.map { entry -> [String: Any] in
            let url = entry.url.standardizedFileURL
            return [
                "id": entry.id.uuidString,
                "name": entry.name,
                "path": entry.url.path,
                "isOpen": openURLs.contains(url),
                "isActive": activeURL == url,
                "isVisible": visibleURL == url,
                "isAccessible": entry.isAccessible,
            ]
        }

        var payload: [String: Any] = ["openCount": openDocs.count, "projects": projects]
        if let active {
            payload["active"] = ["name": active.displayName ?? Project.defaultProjectName, "path": active.fileURL?.path ?? ""]
        }
        if let visible {
            payload["visible"] = ["name": visible.displayName ?? Project.defaultProjectName, "path": visible.fileURL?.path ?? ""]
        }
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    private func openProject(_ args: [String: Any]) async throws -> ToolResult {
        let actionPath = "manage_project action='open'"
        try validateUnknownKeys(args, allowed: ["name", "id", "path"], path: actionPath)
        guard let selector = try projectSelector(args, path: actionPath) else {
            throw ToolError("\(actionPath) needs a name, an id from action='list', or a path.")
        }
        let url = try resolveProjectURL(selector)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("No project at \(url.path).")
        }
        let doc = try await AppState.shared.openProjectAsync(at: url)
        bindProject(doc)
        notifyNowEditing(doc)
        let result = ToolResult.ok(Self.jsonString(projectSnapshot(doc, status: "active")) ?? "{}")
        return await shorteningIds(in: result, editor: doc.editorViewModel)
    }

    private func createProject(_ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["name", "fps", "aspectRatio", "quality"], path: "manage_project action='create'")
        if let name = args["name"], !(name is String) {
            throw ToolError("manage_project action='create': 'name' must be a string.")
        }
        let name = args["name"] as? String ?? Project.defaultProjectName
        let settingsArgs = args.filter { ["fps", "aspectRatio", "quality"].contains($0.key) }
        let settings = try settingsArgs.isEmpty ? nil : validateProjectSettings(settingsArgs)
        let doc = try await AppState.shared.createProject(named: name)
        bindProject(doc)
        if let settings {
            _ = try setProjectSettings(doc.editorViewModel, settings)
        }
        notifyNowEditing(doc)
        let result = ToolResult.ok(Self.jsonString(projectSnapshot(doc, status: "created")) ?? "{}")
        return await shorteningIds(in: result, editor: doc.editorViewModel)
    }

    private func closeProject(_ args: [String: Any]) async throws -> ToolResult {
        let actionPath = "manage_project action='close'"
        try validateUnknownKeys(args, allowed: ["name", "id", "path"], path: actionPath)
        let selector = try projectSelector(args, path: actionPath)
        let target: VideoProject
        if let selector {
            let url = try resolveProjectURL(selector).standardizedFileURL
            guard let doc = AppState.shared.openProjects.first(where: {
                $0.fileURL?.standardizedFileURL == url
            }) else {
                throw ToolError("Project at \(url.path) isn't open.")
            }
            target = doc
        } else if let active = sessionProject {
            target = active
        } else {
            throw ToolError("No project is open.")
        }
        let name = target.displayName ?? Project.defaultProjectName
        let wasSelected = sessionProject === target
        do {
            try await AppState.shared.closeProject(target)
        } catch {
            throw ToolError("Couldn't save '\(name)' — project left open. \(error.localizedDescription)")
        }
        if wasSelected { bindProject(nil) }
        var payload: [String: Any] = [
            "status": "closed",
            "name": name,
            "openCount": AppState.shared.openProjects.count,
        ]
        if let nowActive = sessionProject {
            payload["active"] = [
                "name": nowActive.displayName ?? Project.defaultProjectName,
                "path": nowActive.fileURL?.path ?? "",
            ]
        }
        if let visible = frontmostProject {
            payload["visible"] = [
                "name": visible.displayName ?? Project.defaultProjectName,
                "path": visible.fileURL?.path ?? "",
            ]
        }
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    private enum ProjectSelector {
        case name(String)
        case id(UUID)
        case path(String)
    }

    private func projectSelector(_ args: [String: Any], path: String) throws -> ProjectSelector? {
        let supplied = ["name", "id", "path"].filter(args.keys.contains)
        if supplied.count > 1 {
            throw ToolError("\(path): provide only one of: name, id, path.")
        }
        guard let key = supplied.first else { return nil }
        guard let value = args.string(key), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("\(path): '\(key)' must be a non-empty string.")
        }
        switch key {
        case "name": return .name(value)
        case "path": return .path(value)
        default:
            guard let id = UUID(uuidString: value) else {
                throw ToolError("\(path): 'id' must be a project id returned by action='list'.")
            }
            return .id(id)
        }
    }

    private func projectSnapshot(_ doc: VideoProject, status: String) -> [String: Any] {
        let editor = doc.editorViewModel
        return [
            "status": status,
            "name": doc.displayName ?? Project.defaultProjectName,
            "path": doc.fileURL?.path ?? "",
            "fps": editor.timeline.fps,
            "resolution": "\(editor.timeline.width)x\(editor.timeline.height)",
            "mediaCount": editor.mediaAssets.count,
            "canGenerate": Self.canGenerate,
            "timelines": timelineEntries(editor),
            "openCount": AppState.shared.openProjects.count,
        ]
    }

    private func resolveProjectURL(_ selector: ProjectSelector) throws -> URL {
        switch selector {
        case .path(let path):
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        case .id(let id):
            guard let entry = ProjectRegistry.shared.entries.first(where: { $0.id == id }) else {
                throw ToolError("No project with id \(id). Call manage_project with action='list' for valid ids.")
            }
            return entry.url
        case .name(let name):
            let matches = ProjectRegistry.shared.entries.filter {
                $0.name.compare(name, options: .caseInsensitive) == .orderedSame
            }
            switch matches.count {
            case 1: return matches[0].url
            case 0:
                let known = ProjectRegistry.shared.sortedEntries.prefix(15).map(\.name)
                throw ToolError("No project named '\(name)'. Known projects: \(known.joined(separator: ", ")). Call manage_project with action='list' for the full list.")
            default:
                throw ToolError("\(matches.count) projects are named '\(name)'. Pick one by path: \(matches.map { $0.url.path }.joined(separator: ", "))")
            }
        }
    }

    private func notifyNowEditing(_ doc: VideoProject) {
        let name = doc.displayName ?? Project.defaultProjectName
        doc.editorViewModel.agentService.postSystemNotice("Now editing: \(name)")
    }
}
