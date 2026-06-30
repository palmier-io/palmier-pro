import Foundation
import Observation

@Observable
@MainActor
final class AgentService {

    private var anthropicAPIKey: String = ""
    private var openAICompatibleSettings: OpenAICompatibleSettings?
    private var zhipuSettings: OpenAICompatibleSettings?
    private var codexOAuthSettings: OpenAICompatibleSettings?
    private var providerPreference: AgentProviderPreference = .palmier
    private var providerObservers: [NSObjectProtocol] = []

    init() {
        reloadProviderConfiguration()
        for name in [
            Notification.Name.anthropicAPIKeyChanged,
            .openAICompatibleSettingsChanged,
            .zhipuAgentSettingsChanged,
            .codexOAuthAgentSettingsChanged,
            .agentProviderChanged,
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reloadProviderConfiguration()
                }
            }
            providerObservers.append(observer)
        }
    }

    private func reloadProviderConfiguration() {
        Task { [weak self] in
            let config = await Task.detached(priority: .utility) {
                let anthropicKey = AnthropicKeychain.load() ?? ""
                let openAISettings = OpenAICompatibleSettings.load()
                let zhipuSettings = ZhipuAgentSettings.load()
                let codexOAuthSettings = CodexOAuthAgentSettings.load()
                return (
                    anthropicKey,
                    openAISettings,
                    zhipuSettings,
                    codexOAuthSettings,
                    AgentProviderPreference.defaultProvider(
                        hasAnthropicKey: !anthropicKey.isEmpty,
                        hasOpenAICompatibleConfig: openAISettings != nil,
                        hasZhipuConfig: zhipuSettings != nil,
                        hasCodexOAuthConfig: codexOAuthSettings != nil
                    )
                )
            }.value
            self?.anthropicAPIKey = config.0
            self?.openAICompatibleSettings = config.1
            self?.zhipuSettings = config.2
            self?.codexOAuthSettings = config.3
            self?.providerPreference = config.4
        }
    }

    isolated deinit {
        for token in providerObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    var activeProvider: AgentProviderPreference { providerPreference }

    var hasApiKey: Bool {
        hasAnthropicAPIKey ||
        (openAICompatibleSettings?.hasAPIKey ?? false) ||
        (zhipuSettings?.hasAPIKey ?? false) ||
        (codexOAuthSettings?.hasAPIKey ?? false)
    }

    var hasAnthropicAPIKey: Bool { !anthropicAPIKey.isEmpty }

    var hasOpenAICompatibleEndpoint: Bool { openAICompatibleSettings != nil }

    var hasZhipuEndpoint: Bool { zhipuSettings != nil }

    var hasCodexOAuthEndpoint: Bool { codexOAuthSettings != nil }

    var isUsingBYOK: Bool {
        switch activeProvider {
        case .anthropic:
            return hasAnthropicAPIKey
        case .openAICompatible:
            return openAICompatibleSettings?.hasAPIKey == true
        case .zhipu:
            return zhipuSettings?.hasAPIKey == true
        case .codexOAuth:
            return false
        case .palmier:
            return false
        }
    }

    var providerStatusLabel: String {
        switch activeProvider {
        case .palmier:
            return "Palmier"
        case .anthropic:
            return "Anthropic"
        case .openAICompatible:
            return "OpenAI compatible"
        case .zhipu:
            return "Zhipu GLM"
        case .codexOAuth:
            return "Codex OAuth"
        }
    }

    var effectiveModelLabel: String {
        switch activeProvider {
        case .openAICompatible:
            return openAICompatibleSettings?.model ?? "No model"
        case .zhipu:
            return zhipuSettings?.model ?? "No model"
        case .codexOAuth:
            return codexOAuthSettings?.model ?? "No model"
        case .anthropic, .palmier:
            return effectiveModel.displayName
        }
    }

    var canPickModel: Bool {
        activeProvider == .anthropic && hasAnthropicAPIKey
    }

    var canStream: Bool {
        switch activeProvider {
        case .anthropic:
            return hasAnthropicAPIKey
        case .openAICompatible:
            return hasOpenAICompatibleEndpoint
        case .zhipu:
            return hasZhipuEndpoint
        case .codexOAuth:
            return hasCodexOAuthEndpoint
        case .palmier:
            return true
        }
    }

    var availableModels: [AnthropicModel] {
        switch activeProvider {
        case .anthropic:
            return hasAnthropicAPIKey ? AnthropicModel.allCases : []
        case .openAICompatible, .zhipu, .codexOAuth:
            return []
        case .palmier:
            return AnthropicModel.allCases
        }
    }

    private func selectClient() -> (any AgentClient)? {
        let chosen = effectiveModel
        switch activeProvider {
        case .anthropic:
            guard hasAnthropicAPIKey else { return nil }
            return AnthropicClient(apiKey: anthropicAPIKey, model: chosen)
        case .openAICompatible:
            guard let openAICompatibleSettings else { return nil }
            return OpenAICompatibleClient(settings: openAICompatibleSettings)
        case .zhipu:
            guard let zhipuSettings else { return nil }
            return OpenAICompatibleClient(settings: zhipuSettings)
        case .codexOAuth:
            guard let settings = CodexOAuthAgentSettings.load() else { return nil }
            return CodexOAuthClient(model: settings.model)
        case .palmier:
            return PalmierClient(model: chosen)
        }
    }

    var effectiveModel: AnthropicModel {
        let available = availableModels
        if available.contains(model) { return model }
        return available.first ?? .sonnet46
    }

    var model: AnthropicModel = {
        if let raw = UserDefaults.standard.string(forKey: "agentModel"),
           let m = AnthropicModel(rawValue: raw) {
            return m
        }
        return .sonnet46
    }() {
        didSet { UserDefaults.standard.set(model.rawValue, forKey: "agentModel") }
    }

    var sessions: [ChatSession] = []
    var currentSessionId: UUID?
    var messages: [AgentMessage] = []
    var isStreaming: Bool = false
    var streamError: PalmierClientError?
    var onSessionsChanged: (@MainActor () -> Void)?

    var draft: String = ""
    var mentions: [AgentMention] = []
    private static let clipMentionLabelMaxLength = 24

    func attachMention(for asset: MediaAsset) {
        editor?.agentPanelVisible = true
        pruneDetachedMentions()
        guard !mentions.contains(where: { $0.mediaRef == asset.id && !$0.referencesTimelineContext }) else { return }
        let displayName = Self.disambiguatedMentionName(for: asset, existing: mentions)
        appendMentionToken(displayName)
        mentions.append(AgentMention(displayName: displayName, mediaRef: asset.id, type: asset.type))
    }

    func attachMentions(forClipIds clipIds: [String]) {
        guard let editor, !clipIds.isEmpty else { return }
        editor.agentPanelVisible = true
        pruneDetachedMentions()

        let existingClipIds = Set(mentions.compactMap(\.clipId))
        for ref in Self.clipMentionReferences(for: clipIds, editor: editor) where !existingClipIds.contains(ref.clip.id) {
            let displayName = Self.disambiguatedClipMentionName(
                for: ref.clip,
                label: ref.label,
                trackLabel: ref.trackLabel,
                fps: editor.timeline.fps,
                existing: mentions
            )
            appendMentionToken(displayName)
            mentions.append(AgentMention(
                displayName: displayName,
                mediaRef: ref.clip.mediaRef,
                type: ref.clip.mediaType,
                clipId: ref.clip.id
            ))
        }
    }

    func attachSelectedTimelineRangeMention() {
        guard let editor, let range = editor.validSelectedTimelineRange else { return }
        editor.agentPanelVisible = true
        pruneDetachedMentions()

        let timelineRange = AgentTimelineRangeMention(range: range, fps: editor.timeline.fps)
        guard !mentions.contains(where: { $0.timelineRange == timelineRange }) else { return }

        let displayName = Self.disambiguatedTimelineRangeMentionName(for: timelineRange, existing: mentions)
        appendMentionToken(displayName)
        mentions.append(AgentMention(displayName: displayName, timelineRange: timelineRange))
    }

    private func pruneDetachedMentions() {
        mentions.removeAll { !draft.contains("@\($0.displayName)") }
    }

    private func appendMentionToken(_ displayName: String) {
        let needsSpace = !draft.isEmpty && !draft.hasSuffix(" ") && !draft.hasSuffix("\n")
        draft += (needsSpace ? " " : "") + "@\(displayName) "
    }

    static func disambiguatedMentionName(for asset: MediaAsset, existing: [AgentMention]) -> String {
        let base = asset.mentionDisplayName
        if !existing.contains(where: { $0.displayName == base && $0.mediaRef != asset.id }) {
            return base
        }
        let short = String(asset.id.prefix(6))
        return "\(base)#\(short)"
    }

    static func disambiguatedClipMentionName(
        for clip: Clip,
        label: String,
        trackLabel: String,
        fps: Int,
        existing: [AgentMention]
    ) -> String {
        let shortLabel = compactClipMentionLabel(label)
        let base = AgentMention.makeDisplayName(
            from: "\(shortLabel)-\(trackLabel)-\(formatTimecode(frame: clip.startFrame, fps: fps))"
        )
        let fallback = "Clip-\(String(clip.id.prefix(6)))"
        let candidate = base.isEmpty ? fallback : base
        if !existing.contains(where: { $0.displayName == candidate && $0.clipId != clip.id }) {
            return candidate
        }
        let short = String(clip.id.prefix(6))
        return "\(candidate)#\(short)"
    }

    private static func compactClipMentionLabel(_ label: String) -> String {
        let display = AgentMention.makeDisplayName(from: label)
        guard display.count > clipMentionLabelMaxLength else { return display }
        let end = display.index(display.startIndex, offsetBy: clipMentionLabelMaxLength)
        return String(display[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func disambiguatedTimelineRangeMentionName(
        for range: AgentTimelineRangeMention,
        existing: [AgentMention]
    ) -> String {
        let base = AgentMention.makeDisplayName(from: "Range-\(range.startTimecode)-\(range.endTimecode)")
        let fallback = "Range-\(range.startFrame)-\(range.endFrame)"
        let candidate = base.isEmpty ? fallback : base
        if !existing.contains(where: { $0.displayName == candidate && $0.timelineRange != range }) {
            return candidate
        }
        return "\(candidate)#\(range.startFrame)-\(range.endFrame)"
    }

    private struct ClipMentionReference {
        let clip: Clip
        let label: String
        let trackLabel: String
    }

    private static func clipMentionReferences(for clipIds: [String], editor: EditorViewModel) -> [ClipMentionReference] {
        let requested = Set(clipIds)
        var refs: [ClipMentionReference] = []
        for (trackIndex, track) in editor.timeline.tracks.enumerated() {
            let trackLabel = editor.timelineTrackDisplayLabel(at: trackIndex)
            for clip in track.clips where requested.contains(clip.id) {
                refs.append(ClipMentionReference(
                    clip: clip,
                    label: editor.clipDisplayLabel(for: clip),
                    trackLabel: trackLabel
                ))
            }
        }
        return refs
    }

    weak var editor: EditorViewModel? {
        didSet { toolExecutor = editor.map { ToolExecutor(editor: $0) } }
    }
    private var toolExecutor: ToolExecutor?
    private var currentTask: Task<Void, Never>?

    func loadSessions(from projectURL: URL?) {
        sessions = ChatSessionStore.load(from: projectURL)
            .filter { !$0.messages.isEmpty }
            .map {
                var session = $0
                session.isOpen = false
                return session
            }
            .sorted { $0.updatedAt > $1.updatedAt }

        let session = ChatSession()
        sessions.insert(session, at: 0)
        currentSessionId = session.id
        messages = []
        draft = ""
        mentions.removeAll()
        streamError = nil
        toolExecutor?.resetFeedbackState()
    }

    func newChat() {
        currentTask?.cancel()
        syncMessagesIntoCurrentSession()
        if let id = currentSessionId,
           let idx = sessions.firstIndex(where: { $0.id == id }),
           sessions[idx].messages.isEmpty {
            sessions.remove(at: idx)
        }
        let session = ChatSession()
        sessions.insert(session, at: 0)
        currentSessionId = session.id
        messages = []
        streamError = nil
        toolExecutor?.resetFeedbackState()
        onSessionsChanged?()
    }

    var openSessions: [ChatSession] { sessions.filter { $0.isOpen } }

    func selectSession(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        currentTask?.cancel()
        syncMessagesIntoCurrentSession()
        if !sessions[idx].isOpen {
            sessions[idx].isOpen = true
            onSessionsChanged?()
        }
        currentSessionId = id
        messages = sessions[idx].messages
        streamError = nil
    }

    func closeTab(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isOpen = false
        if currentSessionId == id {
            if let next = sessions.first(where: { $0.isOpen }) {
                currentSessionId = next.id
                messages = next.messages
            } else {
                newChat()
                return
            }
        }
        onSessionsChanged?()
    }

    func deleteSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        if currentSessionId == id {
            currentSessionId = sessions.first(where: { $0.isOpen })?.id
            messages = currentSessionId
                .flatMap { id in sessions.first { $0.id == id }?.messages }
                ?? []
        }
        if openSessions.isEmpty { newChat(); return }
        onSessionsChanged?()
    }

    func send(text: String, mentions: [AgentMention]) {
        guard canStream else {
            streamError = .upstream(missingProviderConfigurationMessage)
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let referencedMentions = AgentMentionContext.referencedMentions(mentions, in: trimmed)
        let contextHint = referencedMentions.isEmpty
            ? nil
            : AgentMentionContext.hint(referencedMentions, editor: editor)

        resolveOrphanToolUses()
        messages.append(AgentMessage(
            role: .user, blocks: [.text(trimmed)],
            mentions: referencedMentions, contextHint: contextHint
        ))
        streamError = nil
        kickOffStream()
    }

    private var missingProviderConfigurationMessage: String {
        switch activeProvider {
        case .anthropic:
            return "Add an Anthropic API key to start."
        case .openAICompatible:
            return "Add an OpenAI-compatible base URL and model to start."
        case .zhipu:
            return "Add a Zhipu API key and model to start."
        case .codexOAuth:
            return "Sign in with Codex OAuth and set a model to start."
        case .palmier:
            return "Add your own API key or configure the Palmier backend to start."
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
    }

    private func kickOffStream() {
        currentTask?.cancel()
        isStreaming = true
        currentTask = Task { [weak self] in
            defer {
                self?.isStreaming = false
                self?.syncMessagesIntoCurrentSession()
                self?.onSessionsChanged?()
            }
            await self?.runLoop()
        }
    }

    private func runLoop() async {
        guard let client = selectClient() else {
            streamError = .upstream("No backend available.")
            AgentDebugLog.trace("runLoop no backend")
            return
        }
        AgentDebugLog.trace("runLoop start provider=\(activeProvider.rawValue) messages=\(messages.count)")
        await SkillStore.shared.reloadInBackground()
        let tools = ToolDefinitions.inAppAgent.map {
            AgentToolSchema(name: $0.name.rawValue, description: $0.description, inputSchema: $0.inputSchema)
        }

        loop: while !Task.isCancelled {
            resolveOrphanToolUses()
            let apiMsgs = await apiMessages()
            let assistant = AgentMessage(role: .assistant, blocks: [])
            messages.append(assistant)
            let assistantID = assistant.id
            AgentDebugLog.trace("turn request provider=\(activeProvider.rawValue) apiMessages=\(apiMsgs.count) tools=\(tools.count)")

            do {
                let stream = client.stream(
                    system: AgentInstructions.serverInstructions + SkillStore.shared.promptIndex,
                    tools: tools,
                    messages: apiMsgs
                )

                var stopReason: AgentStopReason = .endTurn
                var textChars = 0
                var toolUseCount = 0

                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let chunk):
                        textChars += chunk.count
                        appendTextDelta(chunk, toAssistant: assistantID)
                    case .toolUseComplete(let id, let name, let inputJSON):
                        toolUseCount += 1
                        AgentDebugLog.trace("stream tool_use name=\(name) id=\(id) inputBytes=\(inputJSON.utf8.count)")
                        appendToolUse(id: id, name: name, inputJSON: inputJSON, toAssistant: assistantID)
                    case .messageStop(let reason):
                        stopReason = reason
                        AgentDebugLog.trace("stream stop reason=\(reason.rawValue)")
                    }
                }
                AgentDebugLog.trace("turn stream complete stop=\(stopReason.rawValue) textChars=\(textChars) toolUses=\(toolUseCount)")

                if stopReason == .toolUse {
                    await runPendingToolUses(assistantID: assistantID)
                    AgentDebugLog.trace("turn continue after tool results")
                    continue loop
                }
                AgentDebugLog.trace("runLoop end stop=\(stopReason.rawValue)")
                break loop
            } catch is CancellationError {
                dropEmptyAssistantTurn(id: assistantID)
                AgentDebugLog.trace("runLoop cancelled")
                break loop
            } catch let err as PalmierClientError {
                dropEmptyAssistantTurn(id: assistantID)
                streamError = err
                AgentDebugLog.trace("runLoop palmier error=\(err.localizedDescription)")
                break loop
            } catch {
                dropEmptyAssistantTurn(id: assistantID)
                streamError = .upstream(error.localizedDescription)
                AgentDebugLog.trace("runLoop error=\(error.localizedDescription)")
                break loop
            }
        }
    }

    private func assistantMessageIndex(id: UUID) -> Int? {
        messages.firstIndex { $0.id == id && $0.role == .assistant }
    }

    private func dropEmptyAssistantTurn(id: UUID) {
        guard let index = assistantMessageIndex(id: id),
              messages[index].blocks.isEmpty else { return }
        messages.remove(at: index)
    }

    private func appendTextDelta(_ chunk: String, toAssistant id: UUID) {
        guard let index = assistantMessageIndex(id: id) else { return }
        if case .text(let existing)? = messages[index].blocks.last {
            messages[index].blocks[messages[index].blocks.count - 1] = .text(existing + chunk)
        } else {
            messages[index].blocks.append(.text(chunk))
        }
    }

    private func appendToolUse(id toolUseID: String, name: String, inputJSON: String, toAssistant assistantID: UUID) {
        guard let index = assistantMessageIndex(id: assistantID) else { return }
        messages[index].blocks.append(.toolUse(id: toolUseID, name: name, inputJSON: inputJSON))
    }

    private func runPendingToolUses(assistantID: UUID) async {
        guard let assistantIndex = assistantMessageIndex(id: assistantID) else { return }
        guard let executor = toolExecutor else {
            messages.append(AgentMessage(role: .user, blocks: [.text("Tool executor unavailable.")]))
            AgentDebugLog.trace("tool executor unavailable")
            return
        }

        let toolUses: [(id: String, name: String, input: String)] = messages[assistantIndex].blocks.compactMap {
            if case let .toolUse(id, name, input) = $0 { return (id, name, input) }
            return nil
        }
        let alreadyResolved = resolvedToolUseIds(afterAssistantAt: assistantIndex)
        AgentDebugLog.trace("tool batch start count=\(toolUses.count) alreadyResolved=\(alreadyResolved.count)")

        var resultBlocks: [AgentContentBlock] = []
        for use in toolUses where !alreadyResolved.contains(use.id) {
            if Task.isCancelled {
                resultBlocks.append(.toolResult(toolUseId: use.id, content: [.text("Cancelled")], isError: true))
                AgentDebugLog.trace("tool cancelled name=\(use.name) id=\(use.id)")
                continue
            }
            AgentDebugLog.trace("tool execute start name=\(use.name) id=\(use.id) inputBytes=\(use.input.utf8.count)")
            let result = await executor.execute(name: use.name, args: Self.parseJSONObject(use.input))
            let errorPreview = result.isError ? " error=\(Self.toolResultPreview(result))" : ""
            AgentDebugLog.trace("tool execute end name=\(use.name) id=\(use.id) isError=\(result.isError) blocks=\(result.content.count)\(errorPreview)")
            resultBlocks.append(.toolResult(toolUseId: use.id, content: result.content, isError: result.isError))
        }
        if !resultBlocks.isEmpty {
            messages.append(AgentMessage(role: .user, blocks: resultBlocks))
            AgentDebugLog.trace("tool batch appended results=\(resultBlocks.count) totalMessages=\(messages.count)")
        } else {
            AgentDebugLog.trace("tool batch no new results")
        }
    }

    private func resolvedToolUseIds(afterAssistantAt index: Int) -> Set<String> {
        let next = index + 1
        guard next < messages.count, messages[next].role == .user else { return [] }
        return Set(messages[next].blocks.compactMap {
            if case let .toolResult(id, _, _) = $0 { return id }
            return nil
        })
    }

    private func resolveOrphanToolUses(reason: String = "Cancelled") {
        var i = 0
        while i < messages.count {
            defer { i += 1 }
            guard messages[i].role == .assistant else { continue }
            let toolUseIds: [String] = messages[i].blocks.compactMap {
                if case let .toolUse(id, _, _) = $0 { return id }
                return nil
            }
            guard !toolUseIds.isEmpty else { continue }

            let next = i + 1
            let nextIsToolResult = next < messages.count
                && messages[next].role == .user
                && messages[next].blocks.contains(where: {
                    if case .toolResult = $0 { return true }
                    return false
                })
            let resolved: Set<String> = nextIsToolResult
                ? Set(messages[next].blocks.compactMap {
                    if case let .toolResult(id, _, _) = $0 { return id }
                    return nil
                })
                : []

            let orphans = toolUseIds.filter { !resolved.contains($0) }
            guard !orphans.isEmpty else { continue }

            let synthetic: [AgentContentBlock] = orphans.map {
                .toolResult(toolUseId: $0, content: [.text(reason)], isError: true)
            }
            if nextIsToolResult {
                messages[next].blocks.insert(contentsOf: synthetic, at: 0)
            } else {
                messages.insert(AgentMessage(role: .user, blocks: synthetic), at: next)
            }
        }
    }

    private static func parseJSONObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    private static func toolResultPreview(_ result: ToolResult) -> String {
        let text = result.content.compactMap {
            if case let .text(s) = $0 { return s }
            return nil
        }.joined(separator: " ")
        let compact = text.replacingOccurrences(of: "\n", with: " ")
        return String(compact.prefix(300))
    }

    private func syncMessagesIntoCurrentSession() {
        guard let id = currentSessionId,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].messages = messages
        sessions[idx].updatedAt = Date()
        if sessions[idx].title == "New chat",
           let first = messages.first(where: { $0.role == .user }) {
            sessions[idx].title = Self.title(from: first)
        }
    }

    private func apiMessages() async -> [AgentClientMessage] {
        var result: [AgentClientMessage] = []
        for msg in messages {
            var content = msg.blocks.compactMap(Self.contentBlockJSON)
            if msg.role == .user, !msg.mentions.isEmpty {
                let inlined = await inlineImageBlocks(for: msg.mentions)
                var hint = msg.contextHint ?? AgentMentionContext.hint(msg.mentions, editor: editor)
                if let note = AgentMentionContext.inlineNote(for: inlined) { hint += " " + note }
                content.insert(contentsOf: inlined.blocks, at: 0)
                content.insert(["type": "text", "text": hint], at: 0)
            }
            guard !content.isEmpty else { continue }
            result.append(AgentClientMessage(role: msg.role == .user ? .user : .assistant, content: content))
        }
        return result
    }

    private func inlineImageBlocks(for mentions: [AgentMention]) async -> AgentMentionContext.InlinedMentions {
        var out = AgentMentionContext.InlinedMentions()
        guard let editor else {
            for mention in mentions where mention.type == .image {
                if let mediaRef = mention.mediaRef { out.failures[mediaRef] = "editor unavailable" }
            }
            return out
        }
        // Resolve mention -> URL on the main actor, then encode off it.
        var pending: [(mediaRef: String, url: URL)] = []
        for mention in mentions where mention.type == .image {
            guard let mediaRef = mention.mediaRef else { continue }
            guard let asset = editor.mediaAssets.first(where: { $0.id == mediaRef }) else {
                out.failures[mediaRef] = "asset not in media library"
                continue
            }
            pending.append((mediaRef, asset.url))
        }
        let jobs = pending
        let encoded = await Task.detached(priority: .userInitiated) {
            jobs.map { job in
                (job.mediaRef, ImageEncoder.encode(url: job.url).map { ($0.mime, $0.data.base64EncodedString()) })
            }
        }.value
        for (mediaRef, result) in encoded {
            guard let (mime, base64) = result else {
                out.failures[mediaRef] = "could not read or decode image file"
                continue
            }
            out.blocks.append([
                "type": "image",
                "source": ["type": "base64", "media_type": mime, "data": base64],
            ])
            out.inlinedIds.insert(mediaRef)
        }
        return out
    }

    private static func contentBlockJSON(_ block: AgentContentBlock) -> [String: Any]? {
        switch block {
        case .text(let s):
            guard !s.isEmpty else { return nil }
            return ["type": "text", "text": s]
        case .toolUse(let id, let name, let inputJSON):
            return [
                "type": "tool_use", "id": id, "name": name,
                "input": parseJSONObject(inputJSON),
            ]
        case .toolResult(let toolUseId, let content, let isError):
            let contentJSON: [[String: Any]] = content.map {
                switch $0 {
                case .text(let s): return ["type": "text", "text": s]
                case .image(let base64, let mime):
                    return ["type": "image", "source": ["type": "base64", "media_type": mime, "data": base64]]
                }
            }
            return [
                "type": "tool_result", "tool_use_id": toolUseId,
                "content": contentJSON, "is_error": isError,
            ]
        }
    }

    private static func title(from message: AgentMessage) -> String {
        for block in message.blocks {
            if case let .text(s) = block {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return String(trimmed.prefix(40)) }
            }
        }
        return "New chat"
    }
}

struct AgentMessage: Identifiable, Codable {
    enum Role: String, Codable { case user, assistant }
    let id: UUID
    let role: Role
    var blocks: [AgentContentBlock]
    var mentions: [AgentMention]
    var contextHint: String?

    init(id: UUID = UUID(), role: Role, blocks: [AgentContentBlock], mentions: [AgentMention] = [], contextHint: String? = nil) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.mentions = mentions
        self.contextHint = contextHint
    }
}

enum AgentContentBlock: Codable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolUseId: String, content: [ToolResult.Block], isError: Bool)

    private enum Kind: String, Codable { case text, toolUse, toolResult }
    private enum CodingKeys: String, CodingKey {
        case kind, text, id, name, input, toolUseId, content, isError
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try c.decode(String.self, forKey: .text))
        case .toolUse:
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                inputJSON: try c.decode(String.self, forKey: .input)
            )
        case .toolResult:
            self = .toolResult(
                toolUseId: try c.decode(String.self, forKey: .toolUseId),
                content: try c.decode([ToolResult.Block].self, forKey: .content),
                isError: try c.decode(Bool.self, forKey: .isError)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let s):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(s, forKey: .text)
        case .toolUse(let id, let name, let inputJSON):
            try c.encode(Kind.toolUse, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(inputJSON, forKey: .input)
        case .toolResult(let toolUseId, let content, let isError):
            try c.encode(Kind.toolResult, forKey: .kind)
            try c.encode(toolUseId, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
            try c.encode(isError, forKey: .isError)
        }
    }
}
