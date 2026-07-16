import CoreFoundation
import Foundation

struct ToolError: Error { let message: String; init(_ m: String) { self.message = m } }

/// Shared by the MCP server and the in-app agent.
/// Tool implementations live in the `ToolExecutor+*.swift` extension files.
@MainActor
final class ToolExecutor {
    // In-app chat stays with the editor owned by its project window.
    private weak var inAppEditor: EditorViewModel?
    // External MCP observes the frontmost project only to guard writes.
    private let frontmostProjectProvider: (() -> VideoProject?)?
    // External MCP stays on this project until manage_project rebinds it.
    private weak var boundProject: VideoProject?
    private(set) var mcpSessionActivation = Analytics.SessionActivation()
    let exportQueue: ExportQueue

    var editor: EditorViewModel? {
        frontmostProjectProvider == nil ? inAppEditor : sessionProject?.editorViewModel
    }

    var sessionProject: VideoProject? {
        guard frontmostProjectProvider != nil,
              let project = boundProject,
              AppState.shared.openProjects.contains(where: { $0 === project }) else { return nil }
        return project
    }

    var frontmostProject: VideoProject? { frontmostProjectProvider?() }

    init(editor: EditorViewModel, exportQueue: ExportQueue = .shared) {
        self.inAppEditor = editor
        self.frontmostProjectProvider = nil
        self.exportQueue = exportQueue
    }

    init(projectProvider: @escaping () -> VideoProject?, exportQueue: ExportQueue = .shared) {
        let project = projectProvider()
        self.inAppEditor = nil
        self.frontmostProjectProvider = projectProvider
        self.boundProject = project
        self.exportQueue = exportQueue
    }

    func bindProject(_ project: VideoProject?) {
        guard frontmostProjectProvider != nil else { return }
        boundProject = project
    }

    var feedbackState = FeedbackState()
    var lastTranscriptContext: TranscriptionToolContext?

    func execute(name: String, args: [String: Any], source: String = "agent") async -> ToolResult {
        let started = ContinuousClock.now
        guard let tool = ToolName(rawValue: name) else {
            captureToolAnalytics(
                toolName: name,
                source: source,
                projectId: editor?.projectId,
                status: "failed",
                started: started,
                failureReason: "unknown_tool"
            )
            return .error("Unknown tool: \(name)")
        }
        activateMCPSessionIfNeeded(source: source, toolName: tool.rawValue)

        // project tools act on AppState before editor is available
        switch tool {
        case .manageProject:
            let result = await manageProject(args)
            captureToolAnalytics(
                toolName: tool.rawValue,
                source: source,
                projectId: editor?.projectId,
                status: result.isError ? "failed" : "finished",
                started: started
            )
            return result
        default:
            break
        }

        if !Self.canReadInactiveProject(tool), let error = projectFocusError() {
            return .error(error)
        }

        guard let editor else {
            captureToolAnalytics(
                toolName: tool.rawValue,
                source: source,
                projectId: nil,
                status: "failed",
                started: started,
                failureReason: "editor_unavailable"
            )
            return .error("Editor not available")
        }
        let before = editor.timelines
        let idsBefore = currentIdUniverse(editor)
        let result: ToolResult
        Log.agent.notice(
            "tool start name=\(tool.rawValue)",
            telemetry: "Agent tool started",
            data: ["tool": tool.rawValue, "projectId": editor.projectId ?? "unknown"]
        )
        do {
            let resolved = try expandingIdPrefixes(in: args, editor: editor)
            result = try await run(tool, editor, resolved)
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
            "timelineChanged": editor.timelines != before
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
        captureToolAnalytics(
            toolName: tool.rawValue,
            source: source,
            projectId: editor.projectId,
            status: result.isError ? "failed" : "finished",
            started: started,
            timelineChanged: editor.timelines != before
        )
        // Shorten on pre ∪ post ids: new ids and just-removed ids both stay short.
        return await shorteningIds(in: result, editor: editor, alsoKnown: idsBefore)
    }

    private func activateMCPSessionIfNeeded(source: String, toolName: String) {
        guard source == "mcp", mcpSessionActivation.activate() else { return }
        Analytics.capture(.mcpSessionActivated, properties: [
            "source": "mcp",
            "tool_name": toolName,
        ])
    }

    private func projectFocusError() -> String? {
        guard frontmostProjectProvider != nil else { return nil }
        let session = sessionProject
        let frontmost = frontmostProject
        guard session !== frontmost else { return nil }
        let sessionName = session?.displayName ?? boundProject?.displayName ?? "no project"
        let frontmostName = frontmost?.displayName ?? "no project"
        return "This session is on '\(sessionName)', but '\(frontmostName)' is active in Palmier Pro. Activate '\(sessionName)' or call manage_project with action='open' before making changes."
    }

    private static func canReadInactiveProject(_ tool: ToolName) -> Bool {
        switch tool {
        case .getTimeline, .inspectTimeline, .getMedia, .inspectMedia, .searchMedia,
             .getMulticam, .getTranscript, .detectBeats, .inspectColor, .listModels, .sendFeedback:
            true
        default:
            false
        }
    }

    private func captureToolAnalytics(
        toolName: String,
        source: String,
        projectId: String?,
        status: String,
        started: ContinuousClock.Instant? = nil,
        timelineChanged: Bool? = nil,
        failureReason: String? = nil
    ) {
        var payload: [String: Any] = [
            "tool_name": toolName,
            "source": source,
            "project_id": projectId ?? "unknown",
            "status": status,
        ]
        if let started {
            payload["tool_duration_seconds"] = durationSeconds(since: started)
        }
        if let timelineChanged {
            payload["timeline_changed"] = timelineChanged
        }
        if let failureReason {
            payload["failure_reason"] = failureReason
        }
        Analytics.capture(.agentToolCalled, properties: payload)
    }

    private func durationSeconds(since started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func run(_ tool: ToolName, _ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        switch tool {
        case .getTimeline:   return try getTimeline(editor, args)
        case .getMedia:      return try getMedia(editor, args)
        case .inspectMedia:  return try await inspectMedia(editor, args)
        case .getTranscript: return try await getTranscript(editor, args)
        case .detectBeats:   return try await detectBeats(editor, args)
        case .inspectTimeline: return try await inspectTimeline(editor, args)
        case .searchMedia:   return try await searchMedia(editor, args)
        case .applyColor:    return try applyColor(editor, args)
        case .applyEffect:   return try applyEffect(editor, args)
        case .denoiseAudio:  return try denoiseAudio(editor, args)
        case .inspectColor:  return try await inspectColor(editor, args)
        case .addClips:         return try addClips(editor, args)
        case .insertClips:      return try insertClips(editor, args)
        case .removeClips:      return try removeClips(editor, args)
        case .manageTracks:     return try manageTracks(editor, args)
        case .moveClips:        return try moveClips(editor, args)
        case .applyLayout:      return try applyLayout(editor, args)
        case .setClipProperties: return try setClipProperties(editor, args)
        case .setKeyframes:     return try setKeyframes(editor, args)
        case .splitClips:       return try splitClips(editor, args)
        case .rippleDeleteRanges: return try rippleDeleteRanges(editor, args)
        case .removeWords:   return try await removeWords(editor, args)
        case .removeSilence: return try removeSilence(editor, args)
        case .syncClips:     return try await syncClips(editor, args)
        case .manageMulticam: return try await manageMulticam(editor, args)
        case .changeCam:     return try changeCam(editor, args)
        case .getMulticam:   return try getMulticam(editor, args)
        case .undo:          return try undo(editor)
        case .addTexts:      return try addTexts(editor, args)
        case .updateText:    return try updateText(editor, args)
        case .addCaptions:   return try await addCaptions(editor, args)
        case .exportProject: return try await exportProject(editor, args)
        case .manageExports: return try manageExports(editor, args)
        case .generateVideo: return try generate(editor, args, type: .video)
        case .generateImage: return try generate(editor, args, type: .image)
        case .generateAudio: return try await generateAudio(editor, args)
        case .upscaleMedia:  return try upscaleMedia(editor, args)
        case .importMedia:   return try await importMedia(editor, args)
        case .listModels:    return listModels(args)
        case .organizeMedia: return try organizeMedia(editor, args)
        case .sendFeedback:  return try await sendFeedback(editor, args)
        case .setProjectSettings: return try setProjectSettings(editor, args)
        case .createTimeline:     return try createTimeline(editor, args)
        case .setActiveTimeline:  return try setActiveTimeline(editor, args)
        case .readSkill:     return readSkill(args)
        case .manageProject:
            return await manageProject(args)
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

    func undo(_ editor: EditorViewModel) throws -> ToolResult {
        guard let actionName = editor.undo.undoLatest() else {
            throw ToolError("Nothing to undo.")
        }
        return .ok("Undid: \(actionName). The timeline is restored to its state before that edit; re-read with get_timeline or get_transcript before editing again.")
    }

    // Shared helpers used by tool extensions in other files.

    func asset(_ id: String, editor: EditorViewModel, label: String = "Media asset") throws -> MediaAsset {
        guard let asset = editor.mediaAssets.first(where: { $0.id == id }) else {
            throw ToolError("\(label) not found: \(id)")
        }
        return asset
    }

    /// Media asset, or a synthetic stand-in when `id` names a timeline (nest insertion).
    func clipSource(_ id: String, editor: EditorViewModel, path: String) throws -> MediaAsset {
        if let existing = editor.mediaAssets.first(where: { $0.id == id }) { return existing }
        guard let child = editor.timeline(for: id) else {
            throw ToolError("\(path): media asset or timeline not found: \(id)")
        }
        if let reason = editor.nestBlockReason(childId: id) {
            throw ToolError("\(path): \(reason)")
        }
        let stand = MediaAsset(
            id: child.id,
            url: URL(fileURLWithPath: "/dev/null"),
            type: .sequence,
            name: child.name,
            duration: Double(child.totalFrames) / Double(editor.timeline.fps)
        )
        stand.sourceWidth = child.width
        stand.sourceHeight = child.height
        stand.hasAudio = child.hasAudioClips
        return stand
    }

    nonisolated static func jsonString(_ obj: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Throws if `entry` carries any keys outside `allowed`. `path` prefixes the error (e.g. "entries[3]").
func validateUnknownKeys(_ entry: [String: Any], allowed: Set<String>, path: String) throws {
    let unknown = Set(entry.keys).subtracting(allowed)
    guard unknown.isEmpty else {
        let allowedFields = allowed.isEmpty ? "none" : allowed.sorted().joined(separator: ", ")
        throw ToolError("\(path): unknown field(s) '\(unknown.sorted().joined(separator: "', '"))'. Allowed: \(allowedFields).")
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
        throw ToolError("\(path): invalid color '\(hex)'. Expected '#RGB', '#RRGGBB', or '#RRGGBBAA'.")
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

func isJSONBoolean(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return value is Bool }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
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
        guard let raw = self[key], !isJSONBoolean(raw) else { return nil }
        if let v = raw as? Int { return v }
        if let v = raw as? Double { return safeInt(v) }
        if let v = raw as? NSNumber { return safeInt(v.doubleValue) }
        if let v = raw as? String { return Int(v) }
        return nil
    }
    func double(_ key: String) -> Double? {
        guard let raw = self[key], !isJSONBoolean(raw) else { return nil }
        if let v = raw as? Double { return v }
        if let v = raw as? Int { return Double(v) }
        if let v = raw as? NSNumber { return v.doubleValue }
        if let v = raw as? String { return Double(v) }
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
