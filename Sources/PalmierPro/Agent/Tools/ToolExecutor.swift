import Foundation

struct ToolError: Error { let message: String; init(_ m: String) { self.message = m } }

/// Shared by the MCP server and the in-app agent.
/// Tool implementations live in the `ToolExecutor+*.swift` extension files.
@MainActor
final class ToolExecutor {
    private let editorProvider: () -> EditorViewModel?
    var editor: EditorViewModel? { editorProvider() }

    init(editor: EditorViewModel) {
        self.editorProvider = { [weak editor] in editor }
    }

    init(editorProvider: @escaping () -> EditorViewModel?) {
        self.editorProvider = editorProvider
    }

    private var agentUndoStack: [String] = []
    var feedbackState = FeedbackState()
    var lastTranscriptContext: TranscriptionToolContext?

    func execute(name: String, args: [String: Any]) async -> ToolResult {
        guard let tool = ToolName(rawValue: name) else {
            return .error("Unknown tool: \(name)")
        }

        // project tools act on AppState before editor is available
        switch tool {
        case .getProjects, .openProject, .newProject:
            return await runProjectTool(tool, args)
        default:
            break
        }

        guard let editor else { return .error("Editor not available") }
        let before = editor.timeline
        let result: ToolResult
        let started = ContinuousClock.now
        Log.agent.notice(
            "tool start name=\(tool.rawValue)",
            telemetry: "Agent tool started",
            data: ["tool": tool.rawValue, "projectId": editor.projectId ?? "unknown"]
        )
        do {
            let resolved = try expandingIdPrefixes(in: args, editor: editor)
            result = try await run(tool, editor, resolved)
            // Record any edit that actually changed the timeline so `undo` can revert it.
            if tool != .undo, !result.isError, editor.timeline != before,
               let actionName = editor.undoManager?.undoActionName {
                agentUndoStack.append(actionName)
            }
        } catch let err as ToolError {
            result = .error(err.message)
        } catch {
            result = .error(error.localizedDescription)
        }
        feedbackState.record(result, for: tool)
        let elapsed = started.duration(to: .now).seconds
        let telemetry = result.isError ? "Agent tool failed" : "Agent tool finished"
        let payload: Telemetry.Payload = [
            "tool": tool.rawValue,
            "durationSeconds": elapsed,
            "timelineChanged": editor.timeline != before
        ]
        if result.isError {
            Log.agent.warning(
                "tool failed name=\(tool.rawValue) duration=\(elapsed)",
                telemetry: telemetry,
                data: payload
            )
        } else {
            Log.agent.notice(
                "tool ok name=\(tool.rawValue) duration=\(elapsed)",
                telemetry: telemetry,
                data: payload
            )
        }
        // Shorten on the post-run state so newly created ids in summaries are shortened too.
        return await shorteningIds(in: result, editor: editor)
    }

    private func run(_ tool: ToolName, _ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        switch tool {
        case .getTimeline:   return try getTimeline(editor, args)
        case .getMedia:      return try getMedia(editor)
        case .inspectMedia:  return try await inspectMedia(editor, args)
        case .getTranscript: return try await getTranscript(editor, args)
        case .inspectTimeline: return try await inspectTimeline(editor, args)
        case .searchMedia:   return try await searchMedia(editor, args)
        case .applyColor:    return try applyColor(editor, args)
        case .applyEffect:   return try applyEffect(editor, args)
        case .inspectColor:  return try await inspectColor(editor, args)
        case .addClips:         return try addClips(editor, args)
        case .insertClips:      return try insertClips(editor, args)
        case .removeClips:      return try removeClips(editor, args)
        case .removeTracks:     return try removeTracks(editor, args)
        case .moveClips:        return try moveClips(editor, args)
        case .applyLayout:      return try applyLayout(editor, args)
        case .setClipProperties: return try setClipProperties(editor, args)
        case .setKeyframes:     return try setKeyframes(editor, args)
        case .splitClips:       return try splitClips(editor, args)
        case .rippleDeleteRanges: return try rippleDeleteRanges(editor, args)
        case .removeWords:   return try await removeWords(editor, args)
        case .syncAudio:     return try await syncAudio(editor, args)
        case .undo:          return try undo(editor)
        case .addTexts:      return try addTexts(editor, args)
        case .updateText:    return try updateText(editor, args)
        case .addCaptions:   return try await addCaptions(editor, args)
        case .exportProject: return try await exportProject(editor, args)
        case .generateVideo: return try generate(editor, args, type: .video)
        case .generateImage: return try generate(editor, args, type: .image)
        case .generateAudio: return try await generateAudio(editor, args)
        case .upscaleMedia:  return try upscaleMedia(editor, args)
        case .importMedia:   return try await importMedia(editor, args)
        case .createMatte:   return try await createMatte(editor, args)
        case .listModels:    return listModels(args)
        case .listFolders:   return listFolders(editor)
        case .createFolder:  return try createFolder(editor, args)
        case .moveToFolder:  return try moveToFolder(editor, args)
        case .renameMedia:   return try renameMedia(editor, args)
        case .renameFolder:  return try renameFolder(editor, args)
        case .deleteMedia:   return try deleteMedia(editor, args)
        case .deleteFolder:  return try deleteFolder(editor, args)
        case .sendFeedback:  return try await sendFeedback(editor, args)
        case .setProjectSettings: return try setProjectSettings(editor, args)
        case .readSkill:     return readSkill(args)
        case .getProjects, .openProject, .newProject:
            return await runProjectTool(tool, args)
        }
    }

    func readSkill(_ args: [String: Any]) -> ToolResult {
        guard let id = args.string("id") else {
            return .error("read_skill requires an 'id'.")
        }
        guard let body = SkillStore.shared.body(for: id) else {
            return .error("Unknown skill: \(id)")
        }
        return .ok(body)
    }

    /// Reverts the assistant's most recent timeline edit. Refuses to undo the user's own edits.
    func undo(_ editor: EditorViewModel) throws -> ToolResult {
        guard let expected = agentUndoStack.last else {
            throw ToolError("No assistant edit to undo this session. The user's own edits are theirs to undo.")
        }
        guard let undoManager = editor.undoManager, undoManager.canUndo else {
            agentUndoStack.removeAll()
            throw ToolError("Nothing to undo.")
        }
        guard undoManager.undoActionName == expected else {
            throw ToolError("The most recent change ('\(undoManager.undoActionName)') wasn't made by the assistant — not undoing it.")
        }
        undoManager.undo()
        agentUndoStack.removeLast()
        return .ok("Undid: \(expected). The timeline is restored to its state before that edit; re-read with get_timeline or get_transcript before editing again.")
    }

    // Shared helpers used by tool extensions in other files.

    func asset(_ id: String, editor: EditorViewModel, label: String = "Media asset") throws -> MediaAsset {
        guard let asset = editor.mediaAssets.first(where: { $0.id == id }) else {
            throw ToolError("\(label) not found: \(id)")
        }
        return asset
    }

    func resolveFolderId(
        _ args: [String: Any], editor: EditorViewModel, fallbackReferences: [MediaAsset] = []
    ) throws -> String? {
        if let id = args.string("folderId") {
            guard editor.folder(id: id) != nil else {
                throw ToolError("folderId not found: \(id)")
            }
            return id
        }
        return fallbackReferences.last?.folderId
    }

    nonisolated static func jsonString(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func withUndoGroup<T>(_ editor: EditorViewModel, actionName: String, _ work: () throws -> T) rethrows -> T {
        editor.undoManager?.beginUndoGrouping()
        defer {
            editor.undoManager?.endUndoGrouping()
            editor.undoManager?.setActionName(actionName)
        }
        return try work()
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Throws if `entry` carries any keys outside `allowed`. `path` prefixes the error (e.g. "entries[3]").
func validateUnknownKeys(_ entry: [String: Any], allowed: Set<String>, path: String) throws {
    let unknown = Set(entry.keys).subtracting(allowed)
    guard unknown.isEmpty else {
        throw ToolError("\(path): unknown field(s) '\(unknown.sorted().joined(separator: "', '"))'. Allowed: \(allowed.sorted().joined(separator: ", ")).")
    }
}

protocol DecodableToolArgs: Decodable {
    static var allowedKeys: Set<String> { get }
}

func decodeToolArgs<T: DecodableToolArgs>(_ dict: [String: Any], path: String) throws -> T {
    try validateUnknownKeys(dict, allowed: T.allowedKeys, path: path)
    if let badPath = firstNonFiniteNumberPath(in: dict, path: path) {
        throw ToolError("\(badPath): value must be finite")
    }
    let data: Data
    do { data = try JSONSerialization.data(withJSONObject: dict) }
    catch { throw ToolError("\(path): could not re-serialize args (\(error.localizedDescription))") }
    do {
        return try JSONDecoder().decode(T.self, from: data)
    } catch let e as DecodingError {
        throw ToolError(formatDecodingError(e, path: path))
    } catch {
        throw ToolError("\(path): \(error.localizedDescription)")
    }
}

private func firstNonFiniteNumberPath(in value: Any, path: String) -> String? {
    if let d = value as? Double, !d.isFinite { return path }
    if let n = value as? NSNumber, !n.doubleValue.isFinite { return path }
    if let arr = value as? [Any] {
        for (i, v) in arr.enumerated() {
            if let p = firstNonFiniteNumberPath(in: v, path: "\(path)[\(i)]") { return p }
        }
    }
    if let dict = value as? [String: Any] {
        for (k, v) in dict {
            if let p = firstNonFiniteNumberPath(in: v, path: "\(path).\(k)") { return p }
        }
    }
    return nil
}

private func formatDecodingError(_ error: DecodingError, path: String) -> String {
    func prefix(_ ctx: DecodingError.Context) -> String {
        let trail = ctx.codingPath.map { k in
            k.intValue.map { "[\($0)]" } ?? ".\(k.stringValue)"
        }.joined()
        return path + trail
    }
    switch error {
    case .keyNotFound(let key, let ctx):
        return "\(prefix(ctx)): missing required field '\(key.stringValue)'"
    case .typeMismatch(let type, let ctx):
        return "\(prefix(ctx)): expected \(type), got something else"
    case .valueNotFound(let type, let ctx):
        return "\(prefix(ctx)): missing required \(type) value"
    case .dataCorrupted(let ctx):
        return "\(prefix(ctx)): \(ctx.debugDescription)"
    @unknown default:
        return "\(path): \(error.localizedDescription)"
    }
}

func parseColorHex(_ hex: String?, path: String) throws -> TextStyle.RGBA? {
    guard let hex else { return nil }
    guard let c = TextStyle.RGBA(hex: hex) else {
        throw ToolError("\(path): invalid color '\(hex)'. Expected '#RRGGBB' or '#RRGGBBAA'.")
    }
    return c
}

func parseAlignment(_ raw: String?, path: String) throws -> TextStyle.Alignment? {
    guard let raw else { return nil }
    guard let a = TextStyle.Alignment(rawValue: raw) else {
        throw ToolError("\(path): invalid alignment '\(raw)'. Expected 'left', 'center', or 'right'.")
    }
    return a
}

// Untrusted Double→Int: nil on NaN/Inf/overflow instead of trapping.
func safeInt(_ d: Double) -> Int? { Int(exactly: d.rounded(.towardZero)) }

// Clamp before converting so the Int(...) can't overflow.
func clampInt(_ d: Double, min lo: Int, max hi: Int) -> Int {
    if d.isNaN || d <= Double(lo) { return lo }
    if d >= Double(hi) { return hi }
    return Int(d.rounded())
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        if let v = self[key] as? String, !v.isEmpty { return v }
        return nil
    }
    func int(_ key: String) -> Int? {
        if let v = self[key] as? Int { return v }
        if let v = self[key] as? Double { return safeInt(v) }
        if let v = self[key] as? NSNumber { return v.intValue }
        if let v = self[key] as? String { return Int(v) }
        return nil
    }
    func double(_ key: String) -> Double? {
        if let v = self[key] as? Double { return v }
        if let v = self[key] as? Int { return Double(v) }
        if let v = self[key] as? NSNumber { return v.doubleValue }
        if let v = self[key] as? String { return Double(v) }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        if let v = self[key] as? Bool { return v }
        if let v = self[key] as? NSNumber { return v.boolValue }
        if let v = self[key] as? String { return Bool(v) }
        return nil
    }
    func stringArray(_ key: String) -> [String] {
        (self[key] as? [Any])?.compactMap { $0 as? String } ?? []
    }
    func requireString(_ key: String) throws -> String {
        guard let v = self[key] as? String else { throw ToolError("Missing required argument: \(key)") }
        return v
    }
    func requireInt(_ key: String) throws -> Int {
        guard let v = int(key) else { throw ToolError("Missing required argument: \(key)") }
        return v
    }
}
