import AppKit
import Foundation

/// MCP server-only project navigation. Runs on AppState/ProjectRegistry before editor loads.
extension ToolExecutor {

    func runProjectTool(_ tool: ToolName, _ args: [String: Any]) async -> ToolResult {
        do {
            switch tool {
            case .getProjects: return try getProjects()
            case .openProject: return try await openProject(args)
            case .newProject:  return try await newProject(args)
            default:           return .error("Not a project tool: \(tool.rawValue)")
            }
        } catch let err as ToolError {
            return .error(err.message)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private func getProjects() throws -> ToolResult {
        let openDocs = AppState.shared.openProjects
        let openURLs = Set(openDocs.compactMap { $0.fileURL?.standardizedFileURL })
        let active = AppState.shared.activeProject
        let activeURL = active?.fileURL?.standardizedFileURL

        // Only registered projects, sorted by most recently opened.
        let projects = ProjectRegistry.shared.sortedEntries.map { entry -> [String: Any] in
            let url = entry.url.standardizedFileURL
            return [
                "id": entry.id.uuidString,
                "name": entry.name,
                "path": entry.url.path,
                "isOpen": openURLs.contains(url),
                "isActive": activeURL == url,
                "isAccessible": entry.isAccessible,
            ]
        }

        var payload: [String: Any] = ["openCount": openDocs.count, "projects": projects]
        if let active {
            payload["active"] = ["name": active.displayName ?? Project.defaultProjectName, "path": active.fileURL?.path ?? ""]
        }
        return .ok(Self.jsonString(payload) ?? "{}")
    }

    private func openProject(_ args: [String: Any]) async throws -> ToolResult {
        let url = try resolveProjectURL(args)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("No project at \(url.path).")
        }
        let doc = try await AppState.shared.openProjectAsync(at: url)
        notifyNowEditing(doc)
        return .ok("Now editing “\(doc.displayName ?? Project.defaultProjectName)”. \(AppState.shared.openProjects.count) project(s) open.")
    }

    private func newProject(_ args: [String: Any]) async throws -> ToolResult {
        let name = args.string("name") ?? Project.defaultProjectName
        let doc = try await AppState.shared.createProject(named: name)
        notifyNowEditing(doc)
        return .ok("Created and now editing “\(doc.displayName ?? name)” at \(doc.fileURL?.path ?? "").")
    }

    private func resolveProjectURL(_ args: [String: Any]) throws -> URL {
        if let path = args.string("path"), !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if let id = args.string("id"), !id.isEmpty {
            guard let entry = ProjectRegistry.shared.entries.first(where: { $0.id.uuidString == id }) else {
                throw ToolError("No project with id \(id). Call get_projects for valid ids.")
            }
            return entry.url
        }
        throw ToolError("open_project needs an id (from get_projects) or a path.")
    }

    private func notifyNowEditing(_ doc: VideoProject) {
        let name = doc.displayName ?? Project.defaultProjectName
        doc.editorViewModel.agentService.postSystemNotice("Now editing: \(name)")
    }
}
