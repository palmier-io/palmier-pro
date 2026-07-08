import AppKit
import Foundation

/// MCP server-only project navigation. Runs on AppState/ProjectRegistry before editor loads.
extension ToolExecutor {

    func runProjectTool(_ tool: ToolName, _ args: [String: Any]) async -> ToolResult {
        do {
            switch tool {
            case .getProjects:  return try getProjects()
            case .openProject:  return try await openProject(args)
            case .newProject:   return try await newProject(args)
            case .closeProject: return try await closeProject(args)
            default:            return .error("Not a project tool: \(tool.rawValue)")
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
        let result = ToolResult.ok(Self.jsonString(projectSnapshot(doc, status: "active")) ?? "{}")
        return await shorteningIds(in: result, editor: doc.editorViewModel)
    }

    private func newProject(_ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["name", "fps", "aspectRatio", "quality"], path: "new_project")
        let name = args.string("name") ?? Project.defaultProjectName
        let settingsArgs = args.filter { ["fps", "aspectRatio", "quality"].contains($0.key) }
        if !settingsArgs.isEmpty { try validateProjectSettings(settingsArgs) }
        let doc = try await AppState.shared.createProject(named: name)
        if !settingsArgs.isEmpty {
            _ = try setProjectSettings(doc.editorViewModel, settingsArgs)
        }
        notifyNowEditing(doc)
        let result = ToolResult.ok(Self.jsonString(projectSnapshot(doc, status: "created")) ?? "{}")
        return await shorteningIds(in: result, editor: doc.editorViewModel)
    }

    private func closeProject(_ args: [String: Any]) async throws -> ToolResult {
        try validateUnknownKeys(args, allowed: ["name", "id", "path"], path: "close_project")
        let target: VideoProject
        if args.string("name") != nil || args.string("id") != nil || args.string("path") != nil {
            let url = try resolveProjectURL(args).standardizedFileURL
            guard let doc = AppState.shared.openProjects.first(where: {
                $0.fileURL?.standardizedFileURL == url
            }) else {
                throw ToolError("Project at \(url.path) isn't open.")
            }
            target = doc
        } else if let active = AppState.shared.activeProject {
            target = active
        } else {
            throw ToolError("No project is open.")
        }
        let name = target.displayName ?? Project.defaultProjectName
        do {
            try await AppState.shared.closeProject(target)
        } catch {
            throw ToolError("Couldn't save '\(name)' — project left open. \(error.localizedDescription)")
        }
        var payload: [String: Any] = [
            "status": "closed",
            "name": name,
            "openCount": AppState.shared.openProjects.count,
        ]
        if let nowActive = AppState.shared.activeProject {
            payload["active"] = [
                "name": nowActive.displayName ?? Project.defaultProjectName,
                "path": nowActive.fileURL?.path ?? "",
            ]
        }
        return .ok(Self.jsonString(payload) ?? "{}")
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
        if let name = args.string("name"), !name.isEmpty {
            let matches = ProjectRegistry.shared.entries.filter {
                $0.name.compare(name, options: .caseInsensitive) == .orderedSame
            }
            switch matches.count {
            case 1: return matches[0].url
            case 0:
                let known = ProjectRegistry.shared.sortedEntries.prefix(15).map(\.name)
                throw ToolError("No project named '\(name)'. Known projects: \(known.joined(separator: ", ")). Call get_projects for the full list.")
            default:
                throw ToolError("\(matches.count) projects are named '\(name)'. Pick one by path: \(matches.map { $0.url.path }.joined(separator: ", "))")
            }
        }
        throw ToolError("open_project needs a name, an id (from get_projects), or a path.")
    }

    private func notifyNowEditing(_ doc: VideoProject) {
        let name = doc.displayName ?? Project.defaultProjectName
        doc.editorViewModel.agentService.postSystemNotice("Now editing: \(name)")
    }
}
