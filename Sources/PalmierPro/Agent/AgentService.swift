import Foundation
import Observation

@Observable
@MainActor
final class AgentService {

    private var credentials = AgentCredentialSnapshot()
    private var apiKeyObserver: NSObjectProtocol?
    private let userDefaults: UserDefaults
    private var reasoningEfforts: [AgentModel: AgentReasoningEffort]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.model = userDefaults.string(forKey: "agentModel")
            .flatMap(AgentModel.persisted)
            ?? .defaultModel
        self.reasoningEfforts = Dictionary(uniqueKeysWithValues: AgentModel.allCases.map {
            ($0, AgentReasoningPreferences.effort(for: $0, defaults: userDefaults))
        })
        reloadAPIKeys()
        apiKeyObserver = NotificationCenter.default.addObserver(
            forName: .agentAPIKeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadAPIKeys()
            }
        }
    }

    private func reloadAPIKeys() {
        Task { [weak self] in
            let credentials = await AgentCredentialSnapshot.loadFromKeychain()
            self?.credentials = credentials
        }
    }

    isolated deinit {
        if let token = apiKeyObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    var route: AgentRoute {
        AgentRouting.route(
            model: model,
            credentials: credentials,
            hasHostedCredits: AccountService.shared.isSignedIn && AccountService.shared.hasCredits,
            hasPaidPlan: AccountService.shared.isPaid
        )
    }

    var canStream: Bool {
        route != .unavailable
    }

    var availableModels: [AgentModel] { AgentModel.allCases }

    func canSelectModel(_ candidate: AgentModel) -> Bool {
        !candidate.requiresPaidHostedPlan
            || AccountService.shared.isPaid
            || !credentials[candidate.provider].isEmpty
    }

    var activeBYOKProvider: AgentProvider? {
        route == .direct ? model.provider : nil
    }

    var reasoningEffort: AgentReasoningEffort {
        get { reasoningEfforts[model, default: .medium] }
        set {
            guard model.supportedReasoningEfforts.contains(newValue) else { return }
            reasoningEfforts[model] = newValue
            AgentReasoningPreferences.set(newValue, for: model, defaults: userDefaults)
        }
    }

    func snapshotRunSettings() -> AgentRunSettings {
        AgentRunSettings(model: model, reasoningEffort: reasoningEffort)
    }

    private func selectClient(for settings: AgentRunSettings) async -> (any AgentClient)? {
        // Re-read keys so changes made mid-session affect the next send.
        let credentials = await AgentCredentialSnapshot.loadFromKeychain()
        self.credentials = credentials

        switch AgentRouting.route(
            model: settings.model,
            credentials: credentials,
            hasHostedCredits: AccountService.shared.isSignedIn && AccountService.shared.hasCredits,
            hasPaidPlan: AccountService.shared.isPaid
        ) {
        case .direct:
            return BYOKClient(
                apiKey: credentials[settings.model.provider],
                settings: settings
            )
        case .hosted:
            return PalmierClient(settings: settings)
        case .unavailable:
            return nil
        }
    }

    var model: AgentModel {
        didSet {
            userDefaults.set(model.rawValue, forKey: "agentModel")
            if case .unavailable = route {
                streamError = .unavailable(model)
            } else if case .some(.unavailable) = streamError {
                streamError = nil
            }
        }
    }

    var sessions: [ChatSession] = []
    var currentSessionId: UUID?
    var messages: [AgentMessage] = []
    var isStreaming: Bool = false
    var streamError: AgentServiceError?
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
            streamError = .unavailable(model)
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let conversationID = currentSessionId else {
            streamError = .upstream("Chat session unavailable.")
            return
        }
        let referencedMentions = AgentMentionContext.referencedMentions(mentions, in: trimmed)
        let contextHint = referencedMentions.isEmpty
            ? nil
            : AgentMentionContext.hint(referencedMentions, editor: editor)
        let runSettings = snapshotRunSettings()
        var sessionActivation = Analytics.SessionActivation(
            isActivated: messages.contains { $0.role == .user }
        )
        let analyticsPayload: [String: Any] = [
            "project_id": editor?.projectId ?? "unknown",
            "model": runSettings.model.rawValue,
        ]
        if sessionActivation.activate() {
            Analytics.capture(.agentSessionStarted, properties: analyticsPayload)
        }

        resolveOrphanToolUses()
        messages.append(AgentMessage(
            role: .user, blocks: [.text(trimmed)],
            mentions: referencedMentions, contextHint: contextHint
        ))
        streamError = nil
        kickOffStream(
            conversationID: conversationID,
            traceID: UUID(),
            settings: runSettings
        )
    }

    func postSystemNotice(_ text: String) {
        messages.append(AgentMessage(role: .system, blocks: [.text(text)]))
        syncMessagesIntoCurrentSession()
        onSessionsChanged?()
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        isStreaming = false
    }

    private func kickOffStream(
        conversationID: UUID,
        traceID: UUID,
        settings: AgentRunSettings
    ) {
        currentTask?.cancel()
        isStreaming = true
        currentTask = Task { [weak self] in
            defer {
                self?.isStreaming = false
                self?.syncMessagesIntoCurrentSession()
                self?.onSessionsChanged?()
            }
            await self?.runLoop(
                conversationID: conversationID,
                traceID: traceID,
                settings: settings
            )
        }
    }

    private func runLoop(
        conversationID: UUID,
        traceID: UUID,
        settings: AgentRunSettings
    ) async {
        let chosenModel = settings.model
        guard let client = await selectClient(for: settings) else {
            streamError = .unavailable(chosenModel)
            return
        }
        if Task.isCancelled { return }
        await SkillStore.shared.reloadInBackground()
        let tools = ToolDefinitions.inAppAgent.map {
            AgentToolSchema(name: $0.name.rawValue, description: $0.description, inputSchema: $0.inputSchema)
        }

        loop: while !Task.isCancelled {
            resolveOrphanToolUses()
            let apiMsgs = await apiMessages()
            guard let inputMessageID = messages.last(where: { $0.role == .user })?.id else {
                streamError = .upstream("The agent request has no user message.")
                break loop
            }
            let assistant = AgentMessage(role: .assistant, blocks: [])
            messages.append(assistant)
            let assistantID = assistant.id

            do {
                let stream = client.stream(
                    system: AgentInstructions.serverInstructions + AgentInstructions.skillsSection(SkillStore.shared.skillIndex),
                    tools: tools,
                    messages: apiMsgs,
                    context: AgentRequestContext(
                        conversationID: conversationID,
                        traceID: traceID,
                        spanID: UUID(),
                        inputMessageID: inputMessageID,
                        outputMessageID: assistantID,
                        projectID: editor?.projectId
                    )
                )

                var stopReason: AgentStopReason = .endTurn

                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .thinkingDelta(let chunk):
                        updateThinking(textDelta: chunk, toAssistant: assistantID)
                    case .thinkingSignature(let signature):
                        updateThinking(signatureDelta: signature, toAssistant: assistantID)
                    case .redactedThinking(let data):
                        appendRedactedThinking(data, toAssistant: assistantID)
                    case .reasoningSummaryDelta(let chunk):
                        appendReasoningDelta(chunk, model: chosenModel, toAssistant: assistantID)
                    case .reasoningComplete(let itemID, let summary, let encryptedContent):
                        completeReasoning(
                            itemID: itemID,
                            summary: summary,
                            encryptedContent: encryptedContent,
                            model: chosenModel,
                            toAssistant: assistantID
                        )
                    case .textDelta(let chunk):
                        appendTextDelta(chunk, toAssistant: assistantID)
                    case .toolUseComplete(let id, let name, let inputJSON):
                        appendToolUse(id: id, name: name, inputJSON: inputJSON, toAssistant: assistantID)
                    case .messageStop(let reason):
                        stopReason = reason
                    }
                }

                dropEmptyAssistantTurn(id: assistantID)
                if stopReason == .refusal {
                    streamError = .refusal(chosenModel)
                    break loop
                }
                if stopReason == .toolUse {
                    await runPendingToolUses(assistantID: assistantID, conversationID: conversationID)
                    if Task.isCancelled { break loop }
                    continue loop
                }
                if Task.isCancelled { break loop }
                break loop
            } catch is CancellationError {
                dropEmptyAssistantTurn(id: assistantID)
                break loop
            } catch let err as AgentServiceError {
                dropEmptyAssistantTurn(id: assistantID)
                streamError = err
                break loop
            } catch {
                dropEmptyAssistantTurn(id: assistantID)
                streamError = .upstream(error.localizedDescription)
                break loop
            }
        }
    }

    private func assistantMessageIndex(id: UUID) -> Int? {
        messages.firstIndex { $0.id == id && $0.role == .assistant }
    }

    func dropEmptyAssistantTurn(id: UUID) {
        guard let index = assistantMessageIndex(id: id) else { return }
        messages[index].blocks.removeAll { !Self.isComplete($0) }
        guard messages[index].blocks.isEmpty else { return }
        messages.remove(at: index)
    }

    private static func isComplete(_ block: AgentContentBlock) -> Bool {
        switch block {
        case .thinking(_, let signature):
            !signature.isEmpty
        case .redactedThinking(let data):
            !data.isEmpty
        case .openAIReasoning(_, let encryptedContent, _, _):
            !encryptedContent.isEmpty
        case .text(let text):
            !text.isEmpty
        case .toolUse, .toolResult:
            true
        }
    }

    private func updateThinking(
        textDelta: String = "",
        signatureDelta: String = "",
        toAssistant id: UUID
    ) {
        guard let index = assistantMessageIndex(id: id) else { return }
        if case .thinking(let text, let signature)? = messages[index].blocks.last {
            messages[index].blocks[messages[index].blocks.count - 1] = .thinking(
                text: text + textDelta,
                signature: signature + signatureDelta
            )
        } else {
            messages[index].blocks.append(.thinking(
                text: textDelta,
                signature: signatureDelta
            ))
        }
    }

    private func appendRedactedThinking(_ data: String, toAssistant id: UUID) {
        guard let index = assistantMessageIndex(id: id) else { return }
        messages[index].blocks.append(.redactedThinking(data: data))
    }

    /// Removes and returns the current streaming reasoning summary for `model`.
    private func takeStreamingReasoningSummary(at index: Int, model: AgentModel) -> String {
        guard case .openAIReasoning(let summary, _, _, let existingModel)?
            = messages[index].blocks.last,
            existingModel == model
        else { return "" }
        messages[index].blocks.removeLast()
        return summary
    }

    private func appendReasoningDelta(_ chunk: String, model: AgentModel, toAssistant id: UUID) {
        guard let index = assistantMessageIndex(id: id) else { return }
        let existing = takeStreamingReasoningSummary(at: index, model: model)
        messages[index].blocks.append(.openAIReasoning(
            summary: existing + chunk,
            encryptedContent: "",
            itemID: nil,
            model: model
        ))
    }

    private func completeReasoning(
        itemID: String?,
        summary: String,
        encryptedContent: String,
        model: AgentModel,
        toAssistant id: UUID
    ) {
        guard let index = assistantMessageIndex(id: id) else { return }
        let existing = takeStreamingReasoningSummary(at: index, model: model)
        messages[index].blocks.append(.openAIReasoning(
            summary: summary.isEmpty ? existing : summary,
            encryptedContent: encryptedContent,
            itemID: itemID,
            model: model
        ))
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

    private func runPendingToolUses(assistantID: UUID, conversationID: UUID) async {
        guard let assistantIndex = assistantMessageIndex(id: assistantID) else { return }
        guard let executor = toolExecutor else {
            messages.append(AgentMessage(role: .user, blocks: [.text("Tool executor unavailable.")]))
            return
        }

        let toolUses: [(id: String, name: String, input: String)] = messages[assistantIndex].blocks.compactMap {
            if case let .toolUse(id, name, input) = $0 { return (id, name, input) }
            return nil
        }
        let alreadyResolved = resolvedToolUseIds(afterAssistantAt: assistantIndex)

        var resultBlocks: [AgentContentBlock] = []
        for use in toolUses where !alreadyResolved.contains(use.id) {
            if Task.isCancelled {
                resultBlocks.append(.toolResult(toolUseId: use.id, content: [.text("Cancelled")], isError: true))
                continue
            }
            let result = await executor.execute(
                name: use.name,
                args: Self.parseJSONObject(use.input),
                sessionID: conversationID.uuidString
            )
            resultBlocks.append(.toolResult(toolUseId: use.id, content: result.content, isError: result.isError))
        }
        if !resultBlocks.isEmpty {
            messages.append(AgentMessage(role: .user, blocks: resultBlocks))
        }
    }

    private func nextNonSystemIndex(after index: Int) -> Int {
        var next = index + 1
        while next < messages.count, messages[next].role == .system { next += 1 }
        return next
    }

    private func resolvedToolUseIds(afterAssistantAt index: Int) -> Set<String> {
        let next = nextNonSystemIndex(after: index)
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

            let next = nextNonSystemIndex(after: i)
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

    private func apiMessages() async -> [AgentRequestMessage] {
        var result: [AgentRequestMessage] = []
        for msg in messages {
            if msg.role == .system { continue }
            var content = msg.blocks.map(AgentRequestBlock.content)
            if msg.role == .user, !msg.mentions.isEmpty {
                let inlined = await inlineImageBlocks(for: msg.mentions)
                var hint = msg.contextHint ?? AgentMentionContext.hint(msg.mentions, editor: editor)
                if let note = AgentMentionContext.inlineNote(for: inlined) { hint += " " + note }
                content.insert(contentsOf: inlined.blocks, at: 0)
                content.insert(.content(.text(hint)), at: 0)
            }
            guard !content.isEmpty else { continue }
            result.append(AgentRequestMessage(role: msg.role == .user ? .user : .assistant, content: content))
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
            out.blocks.append(.image(base64: base64, mediaType: mime))
            out.inlinedIds.insert(mediaRef)
        }
        return out
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
    enum Role: String, Codable { case user, assistant, system }
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

enum AgentContentBlock: Codable, Sendable {
    case thinking(text: String, signature: String)
    case redactedThinking(data: String)
    case openAIReasoning(
        summary: String,
        encryptedContent: String,
        itemID: String?,
        model: AgentModel
    )
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolUseId: String, content: [ToolResult.Block], isError: Bool)

    private enum Kind: String, Codable {
        case thinking, redactedThinking, openAIReasoning, text, toolUse, toolResult
    }
    private enum CodingKeys: String, CodingKey {
        case kind, text, signature, data, id, name, input, toolUseId, content, isError
        case summary, encryptedContent, itemID, model
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .thinking:
            self = .thinking(
                text: try c.decode(String.self, forKey: .text),
                signature: try c.decode(String.self, forKey: .signature)
            )
        case .redactedThinking:
            self = .redactedThinking(data: try c.decode(String.self, forKey: .data))
        case .openAIReasoning:
            self = .openAIReasoning(
                summary: try c.decode(String.self, forKey: .summary),
                encryptedContent: try c.decode(String.self, forKey: .encryptedContent),
                itemID: try c.decodeIfPresent(String.self, forKey: .itemID),
                model: try c.decode(AgentModel.self, forKey: .model)
            )
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
        case .thinking(let text, let signature):
            try c.encode(Kind.thinking, forKey: .kind)
            try c.encode(text, forKey: .text)
            try c.encode(signature, forKey: .signature)
        case .redactedThinking(let data):
            try c.encode(Kind.redactedThinking, forKey: .kind)
            try c.encode(data, forKey: .data)
        case .openAIReasoning(let summary, let encryptedContent, let itemID, let model):
            try c.encode(Kind.openAIReasoning, forKey: .kind)
            try c.encode(summary, forKey: .summary)
            try c.encode(encryptedContent, forKey: .encryptedContent)
            try c.encodeIfPresent(itemID, forKey: .itemID)
            try c.encode(model, forKey: .model)
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
