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
    private var mcpClientInfo: MCPClientInfo?
    private(set) var mcpSessionActivation = Analytics.SessionActivation()
    /// Correlates every tool call of one agent turn. Set by the chat loop; nil for MCP calls,
    /// which get their own session identity from the transport.
    private(set) var currentTurnID: String?
    private let analyticsSessionID = UUID().uuidString
    let exportQueue: ExportQueue
    let skillStore: SkillStore
    let visualSearchModel: any VisualSearchModelLoading
    let capabilityInputLoader: @Sendable () async throws -> RuntimeCapabilities.LocalInputs

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

    init(
        editor: EditorViewModel,
        exportQueue: ExportQueue = .shared,
        skillStore: SkillStore = .shared,
        visualSearchModel: any VisualSearchModelLoading = VisualModelLoader.shared,
        capabilityInputLoader: @escaping @Sendable () async throws -> RuntimeCapabilities.LocalInputs = RuntimeCapabilities.LocalInputs.load
    ) {
        self.inAppEditor = editor
        self.frontmostProjectProvider = nil
        self.exportQueue = exportQueue
        self.skillStore = skillStore
        self.visualSearchModel = visualSearchModel
        self.capabilityInputLoader = capabilityInputLoader
    }

    init(
        projectProvider: @escaping () -> VideoProject?,
        exportQueue: ExportQueue = .shared,
        visualSearchModel: any VisualSearchModelLoading = VisualModelLoader.shared,
        capabilityInputLoader: @escaping @Sendable () async throws -> RuntimeCapabilities.LocalInputs = RuntimeCapabilities.LocalInputs.load
    ) {
        let project = projectProvider()
        self.inAppEditor = nil
        self.frontmostProjectProvider = projectProvider
        self.boundProject = project
        self.exportQueue = exportQueue
        self.skillStore = .shared
        self.visualSearchModel = visualSearchModel
        self.capabilityInputLoader = capabilityInputLoader
    }

    func bindProject(_ project: VideoProject?) {
        guard frontmostProjectProvider != nil else { return }
        boundProject = project
        lastTranscriptSession = nil
    }

    func setMCPClientInfo(_ clientInfo: MCPClientInfo) {
        mcpClientInfo = clientInfo
    }

    var feedbackState = FeedbackState()
    var lastTranscriptSession: TranscriptSession?

    func execute(
        name: String,
        args: [String: Any],
        source: String = "agent",
        sessionID: String? = nil
    ) async -> ToolResult {
        let origin = Analytics.Origin(source: source, sessionID: sessionID ?? analyticsSessionID)
        return await Analytics.$origin.withValue(origin) {
            await executeWithOrigin(name: name, args: args, origin: origin)
        }
    }

    static func droppingAutofilledBlanks(from args: [String: Any]) -> [String: Any] {
        args.filter { !($0.value is NSNull) && ($0.value as? String) != "" }
    }

    private func executeWithOrigin(
        name: String,
        args: [String: Any],
        origin: Analytics.Origin
    ) async -> ToolResult {
        let args = Self.droppingAutofilledBlanks(from: args)
        let started = ContinuousClock.now
        guard let tool = ToolName(rawValue: name),
              origin.source != "mcp"
                || ToolDefinitions.mcpServer.contains(where: { $0.name == tool }) else {
            let result = ToolResult.error("Unknown tool: \(name)")
            captureToolAnalytics(
                toolName: name,
                origin: origin,
                projectId: editor?.projectId,
                result: result,
                started: started,
                failureReason: "unknown_tool"
            )
            return result
        }
        activateMCPSessionIfNeeded(source: origin.source, toolName: tool.rawValue)

        // project tools act on AppState before editor is available
        switch tool {
        case .getCapabilities:
            return await getCapabilities(args, externalClient: origin.source == "mcp")
        case .manageProject:
            let result = await manageProject(args)
            captureToolAnalytics(
                toolName: tool.rawValue,
                origin: origin,
                projectId: editor?.projectId,
                result: result,
                started: started
            )
            return result
        default:
            break
        }

        if !Self.canReadInactiveProject(tool), let error = projectFocusError() {
            let result = ToolResult.error(error)
            captureToolAnalytics(
                toolName: tool.rawValue,
                origin: origin,
                projectId: editor?.projectId,
                result: result,
                started: started,
                failureReason: "project_inactive"
            )
            return result
        }

        guard let editor else {
            let result = ToolResult.error("Editor not available")
            captureToolAnalytics(
                toolName: tool.rawValue,
                origin: origin,
                projectId: nil,
                result: result,
                started: started,
                failureReason: "editor_unavailable"
            )
            return result
        }
        let activeTimelineIdBefore = editor.activeTimelineId
        let nonAgentMutationRevisionBefore = editor.nonAgentTimelineMutationRevision
        let before = editor.timelines
        let idsBefore = currentIdUniverse(editor)
        let result: ToolResult
        var readRevision: Int?
        Log.agent.notice(
            "tool start name=\(tool.rawValue)",
            telemetry: "Agent tool started",
            data: ["tool": tool.rawValue, "projectId": editor.projectId ?? "unknown"]
        )
        do {
            if let badPath = firstOutOfFrameRangePath(in: args, path: tool.rawValue) {
                throw ToolError("\(badPath): integer must be between -\(maxFrameArg) and \(maxFrameArg)")
            }
            AgentDiagnostics.toolBegan(id: currentTurnID ?? "-", name: tool.rawValue)
            let resolved = try expandingIdPrefixes(in: args, editor: editor)
            readRevision = editor.beginAgentTimelineRead(
                timelineReadActivity(for: tool, args: resolved, editor: editor)
            )
            result = try await run(tool, editor, resolved)
        } catch let err as ToolError {
            result = .error(err.message)
        } catch let error as RuntimeCapabilityError {
            result = .error(Self.jsonString(error.capability.receipt) ?? "Capability unavailable.")
        } catch {
            result = .error(error.localizedDescription)
        }
        if let readRevision {
            editor.endAgentTimelineRead(readRevision, succeeded: !result.isError)
        }
        let timelineChanged = editor.timelines != before
        if !result.isError,
           timelineChanged,
           tool.publishesTimelineChanges,
           editor.nonAgentTimelineMutationRevision == nonAgentMutationRevisionBefore,
           editor.activeTimelineId == activeTimelineIdBefore,
           let previousTimeline = before.first(where: { $0.id == activeTimelineIdBefore }) {
            publishAgentChanges(
                before: previousTimeline,
                after: editor.timeline,
                editor: editor
            )
        }
        feedbackState.record(result, for: tool)
        let elapsed = started.duration(to: .now).seconds
        let telemetry = result.isError ? "Agent tool failed" : "Agent tool finished"
        // Recorded outside the success log so an operation that never returns still leaves a
        // trace: the "in flight" line stands alone in the file when nothing follows it.
        AgentDiagnostics.toolFinished(
            id: currentTurnID ?? "-",
            name: tool.rawValue,
            elapsed: elapsed,
            isError: result.isError
        )
        let payload: Telemetry.Payload = [
            "tool": tool.rawValue,
            "durationSeconds": elapsed,
            "timelineChanged": timelineChanged
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
            origin: origin,
            projectId: editor.projectId,
            result: result,
            started: started,
            timelineChanged: timelineChanged
        )
        // Shorten on pre ∪ post ids: new ids and just-removed ids both stay short.
        return await shorteningIds(in: result, editor: editor, alsoKnown: idsBefore)
    }

    private func activateMCPSessionIfNeeded(source: String, toolName: String) {
        guard source == "mcp", mcpSessionActivation.activate() else { return }
        Analytics.capture(.mcpSessionActivated, properties: mcpSessionActivationProperties(toolName: toolName))
    }

    func mcpSessionActivationProperties(toolName: String) -> Analytics.Payload {
        var properties: Analytics.Payload = [
            "source": "mcp",
            "session_id": analyticsSessionID,
            "tool_name": toolName,
        ]
        if let mcpClientInfo {
            properties["client_info"] = mcpClientInfo.payload
        }
        return properties
    }

    private func projectFocusError() -> String? {
        guard frontmostProjectProvider != nil else { return nil }
        let session = sessionProject
        let frontmost = frontmostProject
        guard session !== frontmost else { return nil }
        let sessionName = session?.displayName ?? boundProject?.displayName ?? "no project"
        let frontmostName = frontmost?.displayName ?? "no project"
        return "This session is on '\(sessionName)', but '\(frontmostName)' is active in Compositor Pro. Activate '\(sessionName)' or call manage_project with action='open' before making changes."
    }

    private static func canReadInactiveProject(_ tool: ToolName) -> Bool {
        switch tool {
        case .getTimeline, .inspectTimeline, .getMedia, .inspectMedia, .searchMedia,
             .getMulticam, .getTranscript, .detectBeats, .inspectColor, .listModels,
             .listSpeechVoices, .sendFeedback:
            true
        default:
            false
        }
    }

    private func captureToolAnalytics(
        toolName: String,
        origin: Analytics.Origin,
        projectId: String?,
        result: ToolResult,
        started: ContinuousClock.Instant? = nil,
        timelineChanged: Bool? = nil,
        failureReason: String? = nil
    ) {
        var payload: [String: Any] = [
            "tool_name": toolName,
            "source": origin.source,
            "project_id": projectId ?? "unknown",
            "session_id": origin.sessionID,
            "status": result.isError ? "failed" : "finished",
        ]
        if let started {
            payload["tool_duration_seconds"] = durationSeconds(since: started)
        }
        if let timelineChanged {
            payload["timeline_changed"] = timelineChanged
        }
        if let failureReason = failureReason ?? (result.isError ? "tool_error" : nil) {
            payload["failure_reason"] = failureReason
        }
        if let errorMessage = Self.sanitizedToolErrorMessage(result) {
            payload["error_message"] = errorMessage
        }
        Analytics.capture(.agentToolCalled, properties: payload)
    }

    static func sanitizedToolErrorMessage(_ result: ToolResult) -> String? {
        guard result.isError else { return nil }
        let message = result.content.compactMap { block -> String? in
            guard case .text(let text) = block else { return nil }
            return text
        }.joined(separator: "\n")
        guard !message.isEmpty else { return nil }
        return String(message.prefix(2_048))
            .replacingOccurrences(
                of: #"(?:https?|file)://[^\s\"']+"#,
                with: "[url redacted]",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"/(?:Users|Volumes|private|tmp)(?:/[^\r\n]*)?"#,
                with: "[path redacted]",
                options: .regularExpression
            )
    }

    private func durationSeconds(since started: ContinuousClock.Instant) -> Double {
        let duration = started.duration(to: .now)
        return Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func run(_ tool: ToolName, _ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        switch tool {
        case .getCapabilities: return await getCapabilities(args, externalClient: false)
        case .getTimeline:   return try getTimeline(editor, args)
        case .getMedia:      return try getMedia(editor, args)
        case .inspectMedia:  return try await inspectMedia(editor, args)
        case .captureFrame:  return try await captureFrame(editor, args)
        case .getTranscript: return try await getTranscript(editor, args)
        case .detectBeats:   return try await detectBeats(editor, args)
        case .inspectTimeline: return try await inspectTimeline(editor, args)
        case .searchMedia:   return try await searchMedia(editor, args)
        case .applyColor:    return try applyColor(editor, args)
        case .applyEffect:   return try applyEffect(editor, args)
        case .denoiseAudio:  return try denoiseAudio(editor, args)
        case .debreatheAudio: return try debreatheAudio(editor, args)
        case .enhanceVoice: return try enhanceVoice(editor, args)
        case .matchLoudness: return try matchLoudness(editor, args)
        case .generateDrone: return try await generateDrone(editor, args)
        case .listSpeechVoices: return try listSpeechVoices(args)
        case .generateSpeech: return try await generateSpeech(editor, args)
        case .findStockMedia: return try await findStockMedia(editor, args)
        case .findShotCandidates: return try await findShotCandidates(editor, args)
        case .inspectColor:  return try await inspectColor(editor, args)
        case .addClips:         return try addClips(editor, args)
        case .insertClips:      return try insertClips(editor, args)
        case .removeClips:      return try removeClips(editor, args)
        case .manageClipLinks:  return try manageClipLinks(editor, args)
        case .manageTracks:     return try manageTracks(editor, args)
        case .moveClips:        return try moveClips(editor, args)
        case .applyLayout:      return try applyLayout(editor, args)
        case .generateThumbnail: return try await generateThumbnail(editor, args)
        case .addOutro:          return try addOutro(editor, args)
        case .composeImage:      return try await composeImage(editor, args)
        case .offsetAudio:        return try offsetAudio(editor, args)
        case .freezeClip:         return try freezeClip(editor, args)
        case .syncToBeats:        return try await syncToBeats(editor, args)
        case .manageProxies:      return try await manageProxies(editor, args)
        case .applyStylePreset: return try applyStylePreset(editor, args)
        case .qcTimeline:       return try qcTimeline(editor, args)
        case .setClipSpeedRamp: return try setClipSpeedRamp(editor, args)
        case .crossfadeAudio:   return try crossfadeAudio(editor, args)
        case .duckAudio:        return try await duckAudio(editor, args)
        case .applyTransition:  return try applyTransition(editor, args)
        case .removeTransition: return try removeTransition(editor, args)
        case .swapClipMedia:    return try swapClipMedia(editor, args)
        case .setClipProperties: return try setClipProperties(editor, args)
        case .copyClipSettings: return try copyClipSettings(editor, args)
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
        case .planEdit:     return try planEdit(editor, args)
        case .applyPlan:    return try applyPlan(editor, args)
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
        case .manageMarkers:      return try manageMarkers(editor, args)
        case .readSkill:     return readSkill(args)
        case .manageSkills:  return try await manageSkills(args)
        case .manageProject:
            return await manageProject(args)
        }
    }

    func readSkill(_ args: [String: Any]) -> ToolResult {
        guard let id = args.string("id") else {
            return .error("read_skill requires an 'id'.")
        }
        guard let body = skillStore.body(for: id) else {
            return .error("Unknown skill: \(id)")
        }
        Analytics.captureSkillRead(
            skillID: id,
            skillSHA: skillStore.contentSHA(for: id),
            skillOrigin: skillStore.origin(for: id).rawValue
        )
        return .ok(body)
    }

    func undo(_ editor: EditorViewModel) throws -> ToolResult {
        guard editor.undo.undoLatest() != nil else {
            throw ToolError("Nothing to undo.")
        }
        return .ok("Undid the latest action. The timeline is restored to its state before that edit; re-read with get_timeline or get_transcript before editing again.")
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
        if let existing = editor.mediaAssets.first(where: { $0.id == id }) {
            guard existing.type != .subtitle else {
                throw ToolError("\(path): '\(id)' is a subtitle file and can't be placed as a clip. Use add_captions with subtitleMediaRef to place its cues as captions.")
            }
            return existing
        }
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

/// Parses a delivery platform name, refusing unknown values rather than defaulting them: a
/// silently-substituted platform would put captions under the wrong interface.
func deliveryPlatform(_ raw: String?, path: String) throws -> DeliveryPlatform {
    guard let raw, !raw.isEmpty else { return .generic }
    guard let platform = DeliveryPlatform(rawValue: raw) else {
        let known = DeliveryPlatform.allCases.map(\.rawValue).joined(separator: ", ")
        throw ToolError("\(path): unknown platform '\(raw)'. Expected one of: \(known).")
    }
    return platform
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

/// Frame-domain ceiling for every integer tool argument. 2^40 frames is ~19,000 years at
/// 60 fps, so no real request is affected, while every downstream `+` and `*` on frame
/// or duration values stays far from `Int` overflow. Swift traps on that overflow and the
/// trap is not catchable, so arguments past the ceiling must be refused at the boundary.
let maxFrameArg = 1 << 40

/// Speed ceiling for the same reason: a clip converts `durationFrames * speed` back to `Int`.
let maxSpeedArg: Double = 1000

/// Rejects frame-domain integers no timeline can represent, before any handler does
/// arithmetic on them. Applied once at dispatch so hand-parsed and decoded tools share it.
private func firstOutOfFrameRangePath(in value: Any, path: String) -> String? {
    if let i = exactJSONInt(value), i > maxFrameArg || i < -maxFrameArg { return path }
    if let arr = value as? [Any] {
        for (i, v) in arr.enumerated() {
            if let p = firstOutOfFrameRangePath(in: v, path: "\(path)[\(i)]") { return p }
        }
    }
    if let dict = value as? [String: Any] {
        for (k, v) in dict {
            if let p = firstOutOfFrameRangePath(in: v, path: "\(path).\(k)") { return p }
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

/// Strict JSON integer parsing for identifiers and indexes. Unlike `Dictionary.int`,
/// this rejects fractional numbers and numeric strings.
func exactJSONInt(_ raw: Any?) -> Int? {
    guard let raw, !isJSONBoolean(raw) else { return nil }
    if let value = raw as? Int { return value }
    guard let value = (raw as? NSNumber)?.doubleValue else { return nil }
    return Int(exactly: value)
}

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
