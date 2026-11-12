import Foundation
import Observation

@Observable
@MainActor
final class AgentService {

    private var credentials = AgentCredentialSnapshot()
    private var apiKeyObserver: NSObjectProtocol?
    private var endpointObserver: NSObjectProtocol?
    private let userDefaults: UserDefaults
    @ObservationIgnored private let skillStore: SkillStore?
    private var reasoningEfforts: [AgentModel: AgentReasoningEffort]
    /// The user's own OpenAI-compatible models, each with its own endpoint and credential.
    private(set) var customModels: [CustomAgentModel] = []
    private var customKeys: [UUID: String] = [:]
    /// Which of `customModels` the `.custom` model entry resolves to.
    private(set) var selectedCustomModelID: UUID?

    /// Project package URL, used to persist/load the editing progress summary.
    private let projectURL: URL?

    /// Persisted editing progress, loaded once per project and updated after each
    /// coherent editing action. A new chat loads this instead of full history.
    var editingProgress: EditingProgressSummary = .init()

    /// Maximum input tokens reserved for the chat request (model context minus output
    /// headroom). A 256k model reserves ~32k for output, leaving ~224k for input.
    private let maxInputTokens: Int = 224_000

    init(userDefaults: UserDefaults = .standard, skillStore: SkillStore? = nil, projectURL: URL? = nil) {
        self.projectURL = projectURL
        self.userDefaults = userDefaults
        self.skillStore = skillStore
        let models = CustomModelStore.load(defaults: userDefaults)
        let selection = CustomModelStore.selectedID(defaults: userDefaults)
        let selectedID = models.contains { $0.id == selection } ? selection : models.first?.id
        self.customModels = models
        self.selectedCustomModelID = selectedID
        self.reasoningEfforts = Dictionary(uniqueKeysWithValues: AgentModel.allCases.map {
            ($0, AgentReasoningPreferences.effort(for: $0, defaults: userDefaults))
        })
        let restored = userDefaults.string(forKey: "agentModel")
            .flatMap(AgentModel.persisted)
            ?? .defaultModel
        // A saved custom model is only usable while a model exists to call.
        self.model = restored == .custom && selectedID == nil ? .defaultModel : restored
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
        endpointObserver = NotificationCenter.default.addObserver(
            forName: .agentCustomEndpointChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadCustomModels()
            }
        }
        // Create a default chat session so draft/mentions work without loadSessions().
        newChat()
    }

    private func reloadCustomModels() {
        let models = CustomModelStore.load(defaults: userDefaults)
        let selection = CustomModelStore.selectedID(defaults: userDefaults)
        customModels = models
        if let selection, models.contains(where: { $0.id == selection }) {
            selectedCustomModelID = selection
        } else {
            selectedCustomModelID = models.first?.id
        }
        if model == .custom, selectedCustomModelID == nil {
            model = .defaultModel
        }
        let ids = Set(models.map(\.id))
        customKeys = customKeys.filter { ids.contains($0.key) }
        for model in models where customKeys[model.id] == nil {
            Task { [weak self] in
                let key = await CustomModelStore.loadKey(for: model.id)
                self?.customKeys[model.id] = key
            }
        }
    }

    private func reloadAPIKeys() {
        Task { [weak self] in
            let credentials = await AgentCredentialSnapshot.loadFromKeychain()
            self?.credentials = credentials
            for model in self?.customModels ?? [] {
                let key = await CustomModelStore.loadKey(for: model.id)
                self?.customKeys[model.id] = key
            }
        }
    }

    isolated deinit {
        for task in runTasks.values { task.cancel() }
        if let token = apiKeyObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = endpointObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// The `.custom` model entry resolves to the selected model in the list.
    var customEndpoint: CustomAgentModel? {
        guard let id = selectedCustomModelID else { return nil }
        return customModels.first { $0.id == id }
    }

    var route: AgentRoute {
        AgentRouting.route(
            model: model,
            credentials: credentials,
            hasHostedCredits: AccountService.shared.isSignedIn && AccountService.shared.hasCredits,
            hasPaidPlan: AccountService.shared.isPaid,
            custom: customEndpoint,
            customKey: customKey
        )
    }

    var canStream: Bool {
        route != .unavailable && drainsInProgress == 0
    }

    /// The custom entry only appears once a model exists, so the picker never offers a
    /// model that cannot be called.
    var availableModels: [AgentModel] {
        AgentModel.allCases.filter { $0 != .custom || customEndpoint != nil }
    }

    /// Built-in catalog entries, rendered above the user's own models in the picker.
    var builtInModels: [AgentModel] {
        availableModels.filter { $0 != .custom }
    }

    func canSelectModel(_ candidate: AgentModel) -> Bool {
        if candidate == .custom { return customEndpoint != nil }
        return !candidate.requiresPaidHostedPlan
            || AccountService.shared.isPaid
            || !credentials[candidate.provider].isEmpty
    }

    /// Built-ins show their catalog name; the custom entry shows the selected model's name.
    func modelTitle(_ model: AgentModel) -> String {
        model == .custom ? (customEndpoint?.displayTitle ?? model.displayName) : model.displayName
    }

    private var customKey: String {
        guard let id = selectedCustomModelID else { return "" }
        return customKeys[id] ?? ""
    }

    /// Selects which configured model the `.custom` entry calls.
    func selectCustomModel(_ id: UUID) {
        guard customModels.contains(where: { $0.id == id }) else { return }
        selectedCustomModelID = id
        CustomModelStore.setSelectedID(id, defaults: userDefaults)
        if case .unavailable = route {
            streamError = .unavailable(model)
        } else if case .some(.unavailable) = streamError {
            streamError = nil
        }
    }

    /// Called by Settings after the model list changes.
    func updateCustomEndpoint(_ endpoint: CustomAgentModel?) {
        reloadCustomModels()
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
        AgentRunSettings(model: model, reasoningEffort: reasoningEffort, custom: customEndpoint)
    }

    private func selectClient(for settings: AgentRunSettings) async -> (any AgentClient)? {
        // Re-read keys so changes made mid-session affect the next send.
        let credentials = await AgentCredentialSnapshot.loadFromKeychain()
        self.credentials = credentials
        var customKey = ""
        if let custom = settings.custom {
            customKey = await CustomModelStore.loadKey(for: custom.id)
            customKeys[custom.id] = customKey
        }

        // Local-only routing: no hosted backend remains (R1).
        switch AgentRouting.route(
            model: settings.model,
            credentials: credentials,
            hasHostedCredits: false,
            hasPaidPlan: false,
            custom: settings.custom,
            customKey: customKey
        ) {
        case .direct:
            return BYOKClient(
                apiKey: settings.model == .custom ? customKey : credentials[settings.model.provider],
                settings: settings
            )
        case .hosted:
            return nil
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
    /// The visible message buffer is a projection of the currently viewed session; runs
    /// mutate their own session's store so background streams never touch this buffer.
    var messages: [AgentMessage] {
        get { sessionMessages(currentSessionId) }
        set {
            if currentSessionId == nil {
                // Backward compat: create a default session if none exists (e.g., in tests)
                let session = ChatSession()
                sessions.insert(session, at: 0)
                currentSessionId = session.id
            }
            guard let id = currentSessionId else { return }
            mutateSessionMessages(id) { $0 = newValue }
        }
    }
    /// True while the currently viewed session has a running stream.
    var isStreaming: Bool {
        currentSessionId.map { sessionRunIDs[$0] != nil } ?? false
    }
    var streamError: AgentServiceError? {
        get { currentSessionId.flatMap { sessionErrors[$0] } }
        set {
            guard let id = currentSessionId else { return }
            sessionErrors[id] = newValue
        }
    }
    /// Number of queued messages waiting for the current session.
    var queuedMessageCount: Int {
        currentSessionId.flatMap { sessionQueues[$0]?.count } ?? 0
    }
    /// Current chat status for UI feedback.
    var chatStatus: ChatStatus {
        requestProgress?.phase ?? .idle
    }
    var requestProgress: AgentRequestProgress? {
        currentSessionId.flatMap { sessionProgress[$0] }
    }
    /// The visible draft is a projection of the currently viewed session; each session keeps its own draft.
    var draft: String {
        get { currentSessionId.flatMap { sessionDrafts[$0] } ?? "" }
        set {
            guard let id = currentSessionId else { return }
            sessionDrafts[id] = newValue
        }
    }
    var mentions: [AgentMention] = []
    var onSessionsChanged: (@MainActor () -> Void)?
    private var sessionDrafts: [UUID: String] = [:]
    /// Per-session chat status.
    private var sessionProgress: [UUID: AgentRequestProgress] = [:]
    private static let clipMentionLabelMaxLength = 24

    /// High-level chat status for UI.
    enum ChatStatus: Equatable, Sendable {
        case idle
        case waitingForPreviousRun
        case connecting
        case loadingSkills
        case preparingContext
        case waitingForResponse
        case reasoning
        case preparingTool(String)
        case streaming
        case toolRunning(String)  // tool name
        case toolCompleted(String)
        case error(String)

        @MainActor var displayText: String {
            switch self {
            case .idle: return ""
            case .waitingForPreviousRun: return L10n.string("Finishing previous request…")
            case .connecting: return L10n.string("Connecting…")
            case .loadingSkills: return L10n.string("Loading skills…")
            case .preparingContext: return L10n.string("Preparing request…")
            case .waitingForResponse: return L10n.string("Waiting for response…")
            case .reasoning: return L10n.string("Reasoning…")
            case .preparingTool(let name): return L10n.string("Preparing \(name)…")
            case .streaming: return L10n.string("Generating…")
            case .toolRunning(let name): return L10n.string("Running \(name)…")
            case .toolCompleted(let name): return L10n.string("Completed \(name)")
            case .error(let msg): return L10n.string("Error: \(msg)")
            }
        }

    }

    private func setRequestPhase(_ phase: ChatStatus, conversationID: UUID) {
        sessionProgress[conversationID]?.update(phase)
    }

    private func applyRequestSnapshot(_ snapshot: AgentStreamSnapshot, assistantID: UUID,
                                      conversationID: UUID, runID: UUID, runEditor: EditorViewModel?) {
        guard isCurrentRun(runID, conversationID: conversationID, editor: runEditor) else { return }
        applyStreamSnapshot(snapshot, assistantID: assistantID, conversationID: conversationID)
        guard let activity = snapshot.activity else { return }
        let phase: ChatStatus
        switch activity {
        case .connected: phase = .waitingForResponse
        case .reasoning: phase = .reasoning
        case .generating: phase = .streaming
        case .preparingTool(let name): phase = .preparingTool(name)
        }
        sessionProgress[conversationID]?.update(phase, now: snapshot.receivedAt ?? .now)
        if activity != .connected { sessionProgress[conversationID]?.retry = nil }
    }

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
        guard let id = currentSessionId else { return }
        let currentDraft = sessionDrafts[id] ?? ""
        mentions.removeAll { !currentDraft.contains("@\($0.displayName)") }
    }

    private func appendMentionToken(_ displayName: String) {
        guard let id = currentSessionId else { return }
        let currentDraft = sessionDrafts[id] ?? ""
        let needsSpace = !currentDraft.isEmpty && !currentDraft.hasSuffix(" ") && !currentDraft.hasSuffix("\n")
        sessionDrafts[id] = currentDraft + (needsSpace ? " " : "") + "@\(displayName) "
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
        didSet {
            // A new editor means a new project context; every running stream is stale.
            cancelAllRuns()
            sessionRunIDs.removeAll()
            sessionErrors.removeAll()
            toolExecutor = editor.map {
                ToolExecutor(editor: $0, skillStore: skillStore ?? .shared, userDefaults: userDefaults)
            }
        }
    }
    private var toolExecutor: ToolExecutor?
    @ObservationIgnored private var runTasks: [UUID: Task<Void, Never>] = [:]
    /// Active run per chat session, so multiple sessions can stream in parallel and a
    /// run stays alive while the user views another tab.
    @ObservationIgnored private var sessionRunIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var sessionErrors: [UUID: AgentServiceError] = [:]
    @ObservationIgnored private var sessionSummaries: [UUID: String] = [:]
    /// Queued user messages per session (text, mentions). When the agent is busy,
    /// new messages are appended here and processed sequentially after each turn.
    @ObservationIgnored private var sessionQueues: [UUID: [(text: String, mentions: [AgentMention])]] = [:]
    private static let streamTimeoutRetryLimit = 2
    private var drainsInProgress = 0

    private func sessionMessages(_ id: UUID?) -> [AgentMessage] {
        id.flatMap { sessionID in sessions.first { $0.id == sessionID }?.messages } ?? []
    }

    private func mutateSessionMessages(_ id: UUID, _ change: (inout [AgentMessage]) -> Void) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        change(&sessions[idx].messages)
        sessions[idx].updatedAt = Date()
        if sessions[idx].title == "New chat",
           let first = sessions[idx].messages.first(where: { $0.role == .user }) {
            sessions[idx].title = Self.title(from: first)
        }
    }

    func cancelAllRuns() {
        for task in runTasks.values { task.cancel() }
        sessionRunIDs.removeAll()
        sessionErrors.removeAll()
        sessionProgress.removeAll()
    }

    func loadSessions(from projectURL: URL?) async {
        cancelAllRuns()
        sessions = ChatSessionStore.load(from: projectURL)
            .filter { !$0.messages.isEmpty }
            .map {
                var session = $0
                session.isOpen = false
                return session
            }
            .sorted { $0.updatedAt > $1.updatedAt }
        sessionRunIDs.removeAll()
        sessionErrors.removeAll()
        sessionSummaries.removeAll()
        sessionQueues.removeAll()
        sessionProgress.removeAll()

        editingProgress = await EditingProgressStore.load(from: projectURL)

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
        if let id = currentSessionId {
            if let runID = sessionRunIDs[id] { runTasks[runID]?.cancel() }
            sessionQueues[id] = nil
            if let idx = sessions.firstIndex(where: { $0.id == id }),
               sessions[idx].messages.isEmpty {
                sessions.remove(at: idx)
            }
        }
        let session = ChatSession()
        sessions.insert(session, at: 0)
        currentSessionId = session.id
        sessionDrafts[session.id] = ""
        streamError = nil
        toolExecutor?.resetFeedbackState()
        onSessionsChanged?()
    }

    /// Refresh the persisted editing progress from the current editor state. Called after
    /// each coherent editing action so a new chat can resume without full history.
    func refreshEditingProgress() {
        guard let editor else { return }
        let timeline = editor.timeline
        let clips = timeline.tracks.reduce(0) { $0 + $1.clips.count }
        let durationSeconds = timeline.fps > 0 ? Double(timeline.totalFrames) / Double(timeline.fps) : 0
        let playheadSeconds = timeline.fps > 0 ? Double(editor.activeFrame) / Double(timeline.fps) : 0
        editingProgress = EditingProgressSummary(
            selection: Array(editor.selectedClipIds),
            timeline: EditingProgressSummary.Timeline(
                durationSeconds: durationSeconds,
                trackCount: timeline.tracks.count,
                clipCount: clips,
                fps: timeline.fps,
                resolution: "\(timeline.width)x\(timeline.height)"
            ),
            playheadSeconds: playheadSeconds,
            phase: editingProgress.phase,
            completed: editingProgress.completed,
            inProgress: editingProgress.inProgress,
            blocked: editingProgress.blocked,
            next: editingProgress.next,
            recentEdits: editingProgress.recentEdits,
            handoffNote: editingProgress.handoffNote,
            updatedAt: Date()
        )
        Task.detached(priority: .utility) {
            await EditingProgressStore.save(self.editingProgress, to: self.projectURL)
        }
    }

    /// Record a completed editing step and persist progress.
    func recordProgressStep(_ step: String, phase: String? = nil) {
        var completed = editingProgress.completed
        if !completed.contains(step) { completed.append(step) }
        editingProgress.completed = completed
        if let phase { editingProgress.phase = phase }
        Task.detached(priority: .utility) {
            await EditingProgressStore.save(self.editingProgress, to: self.projectURL)
        }
    }

    /// Set the current editorial phase (e.g. "rough-cut", "color-grade", "export"). Persisted
    /// to the common progress file so any new chat can resume from it.
    func setEditingPhase(_ phase: String) {
        editingProgress.phase = phase
        Task.detached(priority: .utility) {
            await EditingProgressStore.save(self.editingProgress, to: self.projectURL)
        }
    }

    /// Set a handoff note describing what the next agent should do. Persisted to the common
    /// progress file.
    func setHandoffNote(_ note: String) {
        editingProgress.handoffNote = note
        Task.detached(priority: .utility) {
            await EditingProgressStore.save(self.editingProgress, to: self.projectURL)
        }
    }

    /// Mark the next planned steps. Persisted to the common progress file.
    func setNextSteps(_ steps: [String]) {
        editingProgress.next = steps
        Task.detached(priority: .utility) {
            await EditingProgressStore.save(self.editingProgress, to: self.projectURL)
        }
    }

    var openSessions: [ChatSession] { sessions.filter { $0.isOpen } }

    func selectSession(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        // Switching tabs never interrupts a stream: the run keeps writing to its own
        // session and stays visible when the user returns.
        if !sessions[idx].isOpen {
            sessions[idx].isOpen = true
            onSessionsChanged?()
        }
        currentSessionId = id
        streamError = nil
    }

    func closeTab(_ id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isOpen = false
        if currentSessionId == id {
            if let next = sessions.first(where: { $0.isOpen }) {
                currentSessionId = next.id
            } else {
                newChat()
                return
            }
        }
        onSessionsChanged?()
    }

    func deleteSession(_ id: UUID) {
        if let runID = sessionRunIDs[id] { runTasks[runID]?.cancel() }
        sessionQueues[id] = nil
        sessions.removeAll { $0.id == id }
        if currentSessionId == id {
            currentSessionId = sessions.first(where: { $0.isOpen })?.id
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

        // If agent is busy, queue the message for after the current turn completes.
        if drainsInProgress > 0 {
            sessionQueues[conversationID, default: []].append((trimmed, referencedMentions))
            return
        }

        let runSettings = snapshotRunSettings()
        var sessionActivation = Analytics.SessionActivation(
            isActivated: sessionMessages(conversationID).contains { $0.role == .user }
        )
        let analyticsPayload: [String: Any] = [
            "project_id": editor?.projectId ?? "unknown",
            "model": runSettings.model.rawValue,
        ]
        if sessionActivation.activate() {
            Analytics.capture(.agentSessionStarted, properties: analyticsPayload)
        }

        resolveOrphanToolUses(conversationID: conversationID)
        mutateSessionMessages(conversationID) { $0.append(AgentMessage(
            role: .user, blocks: [.text(trimmed)],
            mentions: referencedMentions, contextHint: contextHint
        )) }
        streamError = nil
        kickOffStream(
            conversationID: conversationID,
            traceID: UUID(),
            settings: runSettings
        )
    }

    func postSystemNotice(_ text: String) {
        guard let conversationID = currentSessionId else { return }
        mutateSessionMessages(conversationID) { $0.append(AgentMessage(role: .system, blocks: [.text(text)])) }
        onSessionsChanged?()
    }

    func cancel() {
        guard let id = currentSessionId, let runID = sessionRunIDs[id] else { return }
        runTasks[runID]?.cancel()
        sessionRunIDs[id] = nil
        sessionProgress[id] = nil
        onSessionsChanged?()
    }

    func cancelAndWait() async {
        drainsInProgress += 1
        defer { drainsInProgress -= 1 }
        let tasks = Array(runTasks.values)
        for task in tasks { task.cancel() }
        for task in tasks { await task.value }
        sessionProgress.removeAll()
        onSessionsChanged?()
    }

    @discardableResult
    func kickOffStream(
        conversationID: UUID,
        traceID: UUID,
        settings: AgentRunSettings,
        client: (any AgentClient)? = nil
    ) -> Task<Void, Never> {
        guard drainsInProgress == 0 else { return Task {} }
        // Replace only this session's own run; other sessions keep streaming in parallel.
        let previousTask = sessionRunIDs[conversationID].flatMap { runTasks[$0] }
        previousTask?.cancel()
        sessionErrors[conversationID] = nil
        let runID = UUID()
        sessionRunIDs[conversationID] = runID
        sessionProgress[conversationID] = AgentRequestProgress(
            phase: previousTask == nil ? .connecting : .waitingForPreviousRun,
            providerName: settings.custom?.displayTitle ?? settings.model.provider.displayName
        )
        let task = Task { [weak self, previousTask] in
            defer {
                self?.runTasks.removeValue(forKey: runID)
                if let self, self.sessionRunIDs[conversationID] == runID {
                    self.sessionRunIDs[conversationID] = nil
                    self.sessionProgress[conversationID] = nil
                    self.onSessionsChanged?()
                }
            }
            if let previousTask { await previousTask.value }
            guard !Task.isCancelled else { return }
            await self?.runLoop(
                conversationID: conversationID,
                traceID: traceID,
                settings: settings,
                runID: runID,
                client: client
            )
        }
        runTasks[runID] = task
        return task
    }

    private func runLoop(
        conversationID: UUID,
        traceID: UUID,
        settings: AgentRunSettings,
        runID: UUID,
        client suppliedClient: (any AgentClient)?
    ) async {
        let runEditor = editor
        let chosenModel = settings.model
        let turnID = String(traceID.uuidString.prefix(8))
        AgentDiagnostics.currentTurnID = turnID
        AgentDiagnostics.beginTurn(
            id: turnID,
            settings: settings,
            messageCount: sessionMessages(conversationID).count,
            toolCount: ToolDefinitions.all.count
        )
        setRequestPhase(.connecting, conversationID: conversationID)
        let selectedClient: (any AgentClient)?
        if let suppliedClient { selectedClient = suppliedClient }
        else { selectedClient = await selectClient(for: settings) }
        guard let client = selectedClient else {
            if isCurrentRun(runID, conversationID: conversationID, editor: runEditor) {
                sessionErrors[conversationID] = .unavailable(chosenModel)
                setRequestPhase(.error(L10n.string("Model unavailable")), conversationID: conversationID)
            }
            return
        }
        guard isCurrentRun(runID, conversationID: conversationID, editor: runEditor) else { return }
        let skillStore = skillStore ?? SkillStore.shared
        setRequestPhase(.loadingSkills, conversationID: conversationID)
        await skillStore.waitForSkillSync()
        guard isCurrentRun(runID, conversationID: conversationID, editor: runEditor) else { return }
        await skillStore.reloadSkills()
        guard isCurrentRun(runID, conversationID: conversationID, editor: runEditor) else { return }
        let baseTools = ToolDefinitions.inAppAgent.map {
            AgentToolSchema(name: $0.name.rawValue, description: $0.description, inputSchema: $0.inputSchema)
        }

        // --- Context-window management ---
        // Prune tools to editing-relevant subset when context is tight. Generation/stock/
        // planning tools carry large schemas that inflate every request.
        let editingTools: [ToolName] = [
            .getTimeline, .inspectTimeline, .reviewTimeline, .qcTimeline,
            .manageTracks, .addClips, .insertClips, .moveClips, .removeClips,
            .splitClips, .rippleDeleteRanges, .setClipProperties, .setKeyframes,
            .applyLayout, .setClipSpeedRamp, .applyColor, .applyEffect,
            .applyTextStyle, .addTexts, .updateText, .addCaptions, .translateCaptions,
            .mixAudio, .duckAudio, .crossfadeAudio, .offsetAudio,
            .applyStylePreset, .applyMotionPreset, .manageMarkers,
            .setProjectSettings, .exportProject, .manageExports, .undo,
            .getMedia, .inspectMedia, .searchMedia, .importMedia,
            .getTranscript, .removeWords, .removeSilence,
            .getCapabilities
        ]
        let editingToolSet = Set(editingTools.map { $0.rawValue })
        let sessionMsgs = sessionMessages(conversationID)
        let sessionSummary = sessionSummaries[conversationID] ?? ""
        let contextIsTight = sessionSummary.utf16.count > 2_000 || sessionMsgs.count > 40
        // A targeted edit (one clip, one property) pays only for editing schemas; production runs keep all.
        // A short follow-up ("yes, do it") continues the request it answers, so the whole
        // conversation decides: any earlier generative or production request keeps the full tool set.
        let userRequests = sessionMsgs.compactMap { msg -> String? in
            guard msg.role == .user else { return nil }
            return msg.blocks.compactMap { if case .text(let s) = $0 { return s } else { return nil } }.first
        }
        let latestRequest = userRequests.last ?? ""
        let targetedEdit = userRequests.allSatisfy { ToolDefinitions.isTargetedEdit($0) }
            && !latestRequest.isEmpty
        let editingSubset = Set(ToolDefinitions.editingToolNames.map { $0.rawValue })

        let delegation = AgentDelegation()
        let learningSection = AgentLearningLedger.load(from: userDefaults).playbook().promptSection()

        var streamTimeoutRetries = 0
        var contextCompressionRetries = 0
        var outputContinuationRetries = 0

        loop: while isCurrentRun(runID, conversationID: conversationID, editor: runEditor) {
            setRequestPhase(.preparingContext, conversationID: conversationID)
            resolveOrphanToolUses(conversationID: conversationID)
            let apiMsgs = await apiMessages(conversationID: conversationID)
            let delegationEnabled = await delegation.isEnabled
            let permitsFallback = await delegation.permitsFallback
            guard isCurrentRun(runID, conversationID: conversationID, editor: runEditor) else { break }

            // Tool pruning: a targeted edit sends only editing schemas. Otherwise keep the full
            // set, since any production/generative turn may need generation, planning, or catalog
            // tools; tight context trims only when the request is purely an edit.
            let tools: [AgentToolSchema]
            if targetedEdit {
                tools = baseTools.filter { editingSubset.contains($0.name) }
            } else if contextIsTight, !userRequests.contains(where: { !ToolDefinitions.isTargetedEdit($0) }) {
                tools = baseTools.filter { editingToolSet.contains($0.name) }
            } else {
                tools = baseTools
            }

            // Build system instructions: core + rolling summary + editing progress + delegation + skills.
            var systemParts: [String] = []
            systemParts.append(targetedEdit
                ? AgentInstructions.targetedEditInstructions
                : AgentInstructions.serverInstructions)

            if !sessionSummary.isEmpty {
                systemParts.append("\n\n# Rolling summary of earlier turns\n\(sessionSummary)")
            }
            if !editingProgress.handoffNote.isEmpty || !editingProgress.completed.isEmpty
                || !editingProgress.inProgress.isEmpty || !editingProgress.next.isEmpty {
                var progress = "\n# Editing progress (resumable state)\n"
                if !editingProgress.handoffNote.isEmpty {
                    progress += "- Handoff: \(editingProgress.handoffNote)\n"
                }
                if !editingProgress.inProgress.isEmpty {
                    progress += "- In progress: \(editingProgress.inProgress)\n"
                }
                if !editingProgress.completed.isEmpty {
                    progress += "- Completed: \(editingProgress.completed.joined(separator: ", "))\n"
                }
                if !editingProgress.next.isEmpty {
                    progress += "- Next: \(editingProgress.next.joined(separator: ", "))\n"
                }
                progress += "- Timeline: \(editingProgress.timeline.clipCount) clips, \(editingProgress.timeline.trackCount) tracks, \(editingProgress.timeline.durationSeconds)s\n"
                systemParts.append(progress)
            }

            if delegationEnabled {
                systemParts.append(AgentDelegationTool.instructions)
            } else if permitsFallback {
                systemParts.append(AgentDelegationTool.fallbackInstructions)
            } else {
                systemParts.append(AgentDelegationTool.blockedInstructions)
            }
            if !learningSection.isEmpty {
                systemParts.append("\n\n" + learningSection)
            }
            let skillsSection = AgentInstructions.skillsSection(skillStore.skillIndex)
            if !skillsSection.isEmpty {
                systemParts.append(skillsSection)
            }
            let system = systemParts.joined()

            guard let inputMessageID = sessionMessages(conversationID).last(where: { $0.role == .user })?.id else {
                sessionErrors[conversationID] = .upstream("The agent request has no user message.")
                setRequestPhase(.error(L10n.string("No user message")), conversationID: conversationID)
                break loop
            }
            let assistant = AgentMessage(role: .assistant, blocks: [])
            mutateSessionMessages(conversationID) { $0.append(assistant) }
            let assistantID = assistant.id

            setRequestPhase(.waitingForResponse, conversationID: conversationID)
            do {
                let stream = client.stream(
                    system: system,
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

                let finalSnapshot = try await presentAgentStream(
                    stream,
                    model: chosenModel,
                    turnID: String(traceID.uuidString.prefix(8))
                ) { [weak self] snapshot in
                    await self?.applyRequestSnapshot(
                        snapshot,
                        assistantID: assistantID,
                        conversationID: conversationID,
                        runID: runID,
                        runEditor: runEditor
                    )
                }
                let stopReason = finalSnapshot.stopReason
                streamTimeoutRetries = 0
                guard isCurrentRun(runID, conversationID: conversationID, editor: runEditor) else { break }
                if stopReason != .refusal, stopReason != .maxTokens,
                   !finalSnapshot.blocks.contains(where: {
                       switch $0 {
                       case .text(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                       case .toolUse: return true
                       default: return false
                       }
                   }) {
                    throw AgentClientTransportError.streamError(
                        provider: chosenModel.provider,
                        message: "The provider completed the request without an answer or tool call. Try again or use another model."
                    )
                }

                dropEmptyAssistantTurn(id: assistantID, conversationID: conversationID)
                // Common progress file is the single source of truth a new chat loads to resume.
                refreshEditingProgress()
                guard isCurrentRun(runID, conversationID: conversationID, editor: runEditor) else { break }
                if stopReason == .refusal {
                    sessionErrors[conversationID] = .refusal(chosenModel)
                    break loop
                }
                if stopReason == .maxTokens && outputContinuationRetries < 2 {
                    outputContinuationRetries += 1
                    sessionProgress[conversationID]?.retry = .outputLimit
                    Log.agent.notice("chat stream turn=\(turnID) continued after output truncation retry=\(outputContinuationRetries)")
                    mutateSessionMessages(conversationID) { $0.append(AgentMessage(role: .user, blocks: [.text("Continue previous response.")])) }
                    continue loop
                }
                if stopReason == .maxTokens {
                    sessionErrors[conversationID] = .upstream("The response repeatedly reached the model’s output limit. Ask for a smaller task or use another model.")
                    break loop
                }
                if stopReason == .toolUse {
                    await runPendingToolUses(assistantID: assistantID, conversationID: conversationID,
                                            runID: runID, runEditor: runEditor, settings: settings,
                                            client: client, traceID: traceID, delegation: delegation)
                    if Task.isCancelled { break loop }
                    continue loop
                }
                if Task.isCancelled { break loop }
                break loop
            } catch {
                let timedOut = Self.isStreamTimeout(error)
                if timedOut {
                    discardAssistantTurn(id: assistantID, conversationID: conversationID)
                } else {
                    dropEmptyAssistantTurn(id: assistantID, conversationID: conversationID)
                }
                guard isCurrentRun(runID, conversationID: conversationID, editor: runEditor),
                      !(error is CancellationError), AgentHTTP.urlErrorCode(error) != .cancelled
                else { break loop }

                // Detect context-length exceeded (400) from custom/gateway endpoints:
                // compress context aggressively and retry once.
                let contextExceeded: Bool
                if let httpError = error as? AgentServiceError,
                   case .httpError(let status, _, let message) = httpError {
                    contextExceeded = status == 400
                        && (message.localizedCaseInsensitiveContains("context length")
                            || message.localizedCaseInsensitiveContains("maximum context"))
                } else if let transportError = error as? AgentClientTransportError,
                          case .httpError(_, let status, let body) = transportError {
                    contextExceeded = status == 400
                        && (body.localizedCaseInsensitiveContains("context length")
                            || body.localizedCaseInsensitiveContains("maximum context"))
                } else {
                    contextExceeded = false
                }

                if contextExceeded, contextCompressionRetries == 0 {
                    contextCompressionRetries += 1
                    discardAssistantTurn(id: assistantID, conversationID: conversationID)
                    sessionProgress[conversationID]?.retry = .contextLimit
                    Log.agent.notice("chat turn=\(turnID) context-length exceeded; compressing and retrying")
                    mutateSessionMessages(conversationID) { $0 = Self.compressMessagesForContext($0, keepLastTurns: 2) }
                    sessionSummaries[conversationID] = ""
                    continue loop
                }

                if contextExceeded {
                    sessionErrors[conversationID] = .upstream("Context length exceeded: the conversation is too long for this model. Start a new chat to continue editing from the saved progress file.")
                    break loop
                }

                if timedOut, streamTimeoutRetries < Self.streamTimeoutRetryLimit {
                    streamTimeoutRetries += 1
                    sessionProgress[conversationID]?.retry = .timeout(attempt: streamTimeoutRetries, limit: Self.streamTimeoutRetryLimit)
                    Log.agent.notice("chat stream retry id=\(turnID) reason=timeout retry=\(streamTimeoutRetries)/\(Self.streamTimeoutRetryLimit)")
                    continue loop
                }
                sessionErrors[conversationID] = (error as? AgentServiceError) ?? .upstream(error.localizedDescription)
                setRequestPhase(.error(error.localizedDescription), conversationID: conversationID)
                break loop
            }
        }
        // Process queued messages for this session after the turn completes.
        await processQueueIfNeeded(conversationID: conversationID, runID: runID, runEditor: runEditor, settings: settings, client: client)
    }

    private func processQueueIfNeeded(
        conversationID: UUID,
        runID: UUID,
        runEditor: EditorViewModel?,
        settings: AgentRunSettings,
        client: (any AgentClient)?
    ) async {
        guard var queue = sessionQueues[conversationID], !queue.isEmpty else { return }
        let next = queue.removeFirst()
        sessionQueues[conversationID] = queue
        // Reuse the same run settings but with the queued message as the new input.
        let queuedRunSettings = settings
        mutateSessionMessages(conversationID) { $0.append(AgentMessage(
            role: .user, blocks: [.text(next.text)],
            mentions: next.mentions, contextHint: nil
        )) }
        _ = kickOffStream(
            conversationID: conversationID,
            traceID: UUID(),
            settings: queuedRunSettings,
            client: client
        )
    }

    private func assistantMessageIndex(id: UUID, conversationID: UUID) -> Int? {
        sessionMessages(conversationID).firstIndex { $0.id == id && $0.role == .assistant }
    }

    private static func isStreamTimeout(_ error: any Error) -> Bool {
        if AgentHTTP.urlErrorCode(error) == .timedOut { return true }
        if let error = error as? AgentClientTransportError, case .httpError(_, let status, _) = error {
            return status == 408 || status == 504
        }
        if let error = error as? AgentServiceError, case .httpError(let status, _, _) = error {
            return status == 408 || status == 504
        }
        return false
    }

    private func discardAssistantTurn(id: UUID, conversationID: UUID) {
        mutateSessionMessages(conversationID) {
            guard let index = $0.firstIndex(where: { $0.id == id && $0.role == .assistant }) else { return }
            $0.remove(at: index)
        }
    }

    func applyStreamSnapshot(
        _ snapshot: AgentStreamSnapshot,
        assistantID: UUID,
        conversationID: UUID
    ) {
        if currentSessionId == conversationID {
            guard let index = assistantMessageIndex(id: assistantID, conversationID: conversationID) else { return }
            mutateSessionMessages(conversationID) { $0[index].blocks = snapshot.blocks }
            return
        }

        guard let sessionIndex = sessions.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: {
                  $0.id == assistantID && $0.role == .assistant
              }) else { return }
        sessions[sessionIndex].messages[messageIndex].blocks = snapshot.blocks
        sessions[sessionIndex].updatedAt = Date()
    }

    func dropEmptyAssistantTurn(id messageID: UUID) {
        guard let conversationID = currentSessionId else { return }
        dropEmptyAssistantTurn(id: messageID, conversationID: conversationID)
    }

    func dropEmptyAssistantTurn(id: UUID, conversationID: UUID) {
        mutateSessionMessages(conversationID) {
            guard let index = $0.firstIndex(where: { $0.id == id && $0.role == .assistant }) else { return }
            $0[index].blocks.removeAll { !Self.isComplete($0) }
            if $0[index].blocks.isEmpty {
                $0.remove(at: index)
            }
        }
    }

    private static func isComplete(_ block: AgentContentBlock) -> Bool {
        switch block {
        case .thinking, .redactedThinking, .openAIReasoning:
            AgentContentBlock.isReasoningComplete(block)
        case .text(let text):
            !text.isEmpty
        case .toolUse, .toolResult:
            true
        }
    }

    private func isCurrentRun(_ runID: UUID, conversationID: UUID, editor runEditor: EditorViewModel?) -> Bool {
        !Task.isCancelled && sessionRunIDs[conversationID] == runID && currentSessionId == conversationID && editor === runEditor
    }

    private func runPendingToolUses(assistantID: UUID, conversationID: UUID, runID: UUID,
                                   runEditor: EditorViewModel?, settings: AgentRunSettings,
                                   client: any AgentClient, traceID: UUID, delegation: AgentDelegation) async {
        let sessionMsgs = sessionMessages(conversationID)
        guard let assistantIndex = assistantMessageIndex(id: assistantID, conversationID: conversationID) else { return }
        guard let executor = toolExecutor else {
            mutateSessionMessages(conversationID) { $0.append(AgentMessage(role: .user, blocks: [.text("Tool executor unavailable.")])) }
            return
        }

        let toolUses: [(id: String, name: String, input: String)] = sessionMsgs[assistantIndex].blocks.compactMap {
            if case let .toolUse(id, name, input) = $0 { return (id, name, input) }
            return nil
        }
        let alreadyResolved = resolvedToolUseIds(afterAssistantAt: assistantIndex, conversationID: conversationID)

        var resultBlocks: [AgentContentBlock] = []
        for use in toolUses where !alreadyResolved.contains(use.id) {
            if !isCurrentRun(runID, conversationID: conversationID, editor: runEditor) {
                resultBlocks.append(.toolResult(toolUseId: use.id, content: [.text("Cancelled")], isError: true))
                continue
            }
            let result: ToolResult
            setRequestPhase(.toolRunning(use.name), conversationID: conversationID)
            if use.name == AgentDelegationTool.name {
                result = await executeDelegation(input: use.input, client: client, delegation: delegation,
                    context: AgentRequestContext(conversationID: conversationID, traceID: traceID, spanID: UUID(),
                        inputMessageID: assistantID, outputMessageID: UUID(), projectID: runEditor?.projectId),
                    settings: settings)
            } else {
                result = await executor.execute(
                    name: use.name,
                    args: Self.parseJSONObject(use.input),
                    sessionID: conversationID.uuidString
                )
            }
            resultBlocks.append(.toolResult(toolUseId: use.id, content: result.content, isError: result.isError))
            if isCurrentRun(runID, conversationID: conversationID, editor: runEditor) {
                setRequestPhase(.toolCompleted(use.name), conversationID: conversationID)
            }
        }
        appendToolResults(resultBlocks, conversationID: conversationID)
        // Persist editing progress after each batch of tool results so a new chat can
        // resume without replaying full history.
        refreshEditingProgress()
    }

    func appendToolResults(_ blocks: [AgentContentBlock], conversationID: UUID) {
        guard !blocks.isEmpty else { return }
        let message = AgentMessage(role: .user, blocks: blocks)
        mutateSessionMessages(conversationID) { $0.append(message) }
        onSessionsChanged?()
    }

    private func nextNonSystemIndex(after index: Int, in msgs: [AgentMessage]? = nil) -> Int {
        let messages = msgs ?? sessionMessages(currentSessionId)
        var next = index + 1
        while next < messages.count, messages[next].role == .system { next += 1 }
        return next
    }

    private func resolvedToolUseIds(afterAssistantAt index: Int, conversationID: UUID) -> Set<String> {
        let sessionMsgs = sessionMessages(conversationID)
        let next = nextNonSystemIndex(after: index, in: sessionMsgs)
        guard next < sessionMsgs.count, sessionMsgs[next].role == .user else { return [] }
        return Set(sessionMsgs[next].blocks.compactMap {
            if case let .toolResult(id, _, _) = $0 { return id }
            return nil
        })
    }

    private func resolveOrphanToolUses(conversationID: UUID, reason: String = "Cancelled") {
        var sessionMsgs = sessionMessages(conversationID)
        var i = 0
        while i < sessionMsgs.count {
            defer { i += 1 }
            guard sessionMsgs[i].role == .assistant else { continue }
            let toolUseIds: [String] = sessionMsgs[i].blocks.compactMap {
                if case let .toolUse(id, _, _) = $0 { return id }
                return nil
            }
            guard !toolUseIds.isEmpty else { continue }

            let next = nextNonSystemIndex(after: i, in: sessionMsgs)
            let nextIsToolResult = next < sessionMsgs.count
                && sessionMsgs[next].role == .user
                && sessionMsgs[next].blocks.contains(where: {
                    if case .toolResult = $0 { return true }
                    return false
                })
            let resolved: Set<String> = nextIsToolResult
                ? Set(sessionMsgs[next].blocks.compactMap {
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
                sessionMsgs[next].blocks.insert(contentsOf: synthetic, at: 0)
            } else {
                sessionMsgs.insert(AgentMessage(role: .user, blocks: synthetic), at: next)
            }
        }
        mutateSessionMessages(conversationID) { $0 = sessionMsgs }
    }

    private static func parseJSONObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return obj
    }

    /// Estimate input tokens using a 4-char-per-token approximation. Not exact, but
    /// sufficient for budgeting and pruning decisions before the request is sent.
    private static func estimateTokens(_ text: String) -> Int {
        (text.utf16.count + 3) / 4
    }

    /// Prepare messages for the API with context-window management:
    /// - Sliding window: last 6 turns verbatim, older turns collapsed into a rolling summary
    /// - Rolling summary: compresses old conversation into one compact system message
    /// - Token budget: prunes oldest content first when over budget
    /// - Tool pruning: when context is tight, tool schemas stay out of the message body
    ///   (they are already handled separately by the caller).
    private func apiMessages(conversationID: UUID) async -> [AgentRequestMessage] {
        let sessionMsgs = sessionMessages(conversationID)
        var result: [AgentRequestMessage] = []
        let lastUserIndex = sessionMsgs.lastIndex(where: { $0.role == .user })

        // Build the rolling summary from turns outside the sliding window.
        let windowStart = lastUserIndex.map { max(0, $0 - 6) } ?? 0
        var summaryParts: [String] = []

        for (index, msg) in sessionMsgs.enumerated() {
            if msg.role == .system { continue }

            // Older-than-window turns: extract key facts, drop verbatim content.
            if index < windowStart {
                let summary = summarizeMessage(msg)
                if !summary.isEmpty { summaryParts.append(summary) }
                continue
            }

            var content = msg.blocks.map(AgentRequestBlock.content)
            if msg.role == .user, !msg.mentions.isEmpty {
                let isRecent = lastUserIndex == nil || index >= (lastUserIndex! - 2)
                if isRecent {
                    let inlined = await inlineImageBlocks(for: msg.mentions)
                    var hint = msg.contextHint ?? AgentMentionContext.hint(msg.mentions, editor: editor)
                    if let note = AgentMentionContext.inlineNote(for: inlined) { hint += " " + note }
                    content.insert(contentsOf: inlined.blocks, at: 0)
                    content.insert(.content(.text(hint)), at: 0)
                } else {
                    let hint = msg.contextHint ?? AgentMentionContext.hint(msg.mentions, editor: editor)
                    content.insert(.content(.text(hint + " [Historical image mentions omitted for context budget]")), at: 0)
                }
            }
            let isOldTurn = lastUserIndex != nil && index < (lastUserIndex! - 4)
            if isOldTurn {
                content = content.map { block in
                    if case let .content(inner) = block, case .toolResult(let id, let blocks, let isErr) = inner {
                        let prunedBlocks = blocks.map { b -> ToolResult.Block in
                            if case .image = b {
                                return .text("[Inspection image pruned to fit context budget: superseded by current revision]")
                            }
                            return b
                        }
                        return .content(.toolResult(toolUseId: id, content: prunedBlocks, isError: isErr))
                    }
                    return block
                }
            }
            guard !content.isEmpty else { continue }
            result.append(AgentRequestMessage(role: msg.role == .user ? .user : .assistant, content: content))
        }

        // Inject rolling summary as a leading system message when there is anything to say.
        if !summaryParts.isEmpty {
            sessionSummaries[conversationID] = summaryParts.joined(separator: " ")
        } else {
            sessionSummaries[conversationID] = ""
        }

        // Enforce token budget: estimate total input, prune oldest assistant turns first.
        let systemTokens = 0
        var messageTokens = 0
        for msg in result {
            messageTokens += msg.content.reduce(0) { $0 + Self.estimateTokens(blockText($1)) }
        }
        let totalTokens = systemTokens + messageTokens + Self.estimateTokens(sessionSummaries[conversationID] ?? "")

        if totalTokens > maxInputTokens {
            // Drop oldest assistant turns until under budget, preserving user turns.
            var pruned = result
            while messageTokens > maxInputTokens * 3 / 4, pruned.count > 2 {
                // Remove the oldest non-user turn (assistant/tool).
                if let oldestIdx = pruned.firstIndex(where: { $0.role != .user }) {
                    let removed = pruned.remove(at: oldestIdx)
                    messageTokens -= removed.content.reduce(0) { $0 + Self.estimateTokens(blockText($1)) }
                } else {
                    break
                }
            }
            result = pruned
        }

        return result
    }

    private func blockText(_ block: AgentRequestBlock) -> String {
        switch block {
        case .content(let inner):
            switch inner {
            case .text(let s): return s
            case .toolUse(let id, let name, let input): return "\(id) \(name) \(input)"
            case .toolResult(let id, let blocks, _):
                let parts = blocks.map { b -> String in
                    switch b {
                    case .text(let s): return s
                    case .image(let base64, _): return "[image]"
                    }
                }
                return "\(id) \(parts.joined(separator: " "))"
            case .thinking, .redactedThinking, .openAIReasoning:
                return "[reasoning]"
            }
        case .image(let base64, _): return base64
        }
    }

    /// Compress messages for a context-length retry: keep only the last N turns verbatim,
    /// drop older assistant turns, collapse old user turns into one-line summaries.
    private static func compressMessagesForContext(_ messages: [AgentMessage], keepLastTurns: Int) -> [AgentMessage] {
        guard messages.count > keepLastTurns else { return messages }
        let cutoff = messages.count - keepLastTurns
        var compressed: [AgentMessage] = []
        for (index, msg) in messages.enumerated() {
            if index < cutoff {
                // Collapse old turns to one line.
                switch msg.role {
                case .user:
                    let text = msg.blocks.compactMap { if case .text(let s) = $0 { return s }; return nil }.joined()
                    compressed.append(AgentMessage(role: .user, blocks: [.text("Earlier: \(String(text.prefix(80))).")]))
                case .assistant:
                    let text = msg.blocks.compactMap { if case .text(let s) = $0 { return s }; return nil }.joined()
                    compressed.append(AgentMessage(role: .assistant, blocks: [.text("Earlier assistant: \(String(text.prefix(80))).")]))
                case .system:
                    break
                }
            } else {
                compressed.append(msg)
            }
        }
        return compressed
    }

    /// Compress a single message into a one-line fact for the rolling summary.
    private func summarizeMessage(_ msg: AgentMessage) -> String {
        switch msg.role {
        case .user:
            let text = msg.blocks.compactMap { if case .text(let s) = $0 { return s }; return nil }.joined()
            return "User: \(String(text.prefix(120)))."
        case .assistant:
            let text = msg.blocks.compactMap { if case .text(let s) = $0 { return s }; return nil }.joined()
            let tools = msg.blocks.compactMap { if case .toolUse(_, let name, _) = $0 { return name }; return nil }.joined(separator: ",")
            return "Assistant: \(tools.isEmpty ? String(text.prefix(120)) : "tools: \(tools)")."
        case .system:
            return ""
        }
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

    /// True while this message holds a reasoning block that has not finished arriving.
    ///
    /// The streaming indicator keys off this rather than off `isStreaming`, so a turn that answers
    /// without reasoning is not presented as though the agent thought about it.
    var hasIncompleteReasoning: Bool {
        blocks.contains { !AgentContentBlock.isReasoningComplete($0) }
    }

    init(id: UUID = UUID(), role: Role, blocks: [AgentContentBlock], mentions: [AgentMention] = [], contextHint: String? = nil) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.mentions = mentions
        self.contextHint = contextHint
    }
}

extension AgentContentBlock {
    /// Whether this block is one of the reasoning cases, which the indicator and the disclosure
    /// treat as a group.
    var isReasoning: Bool {
        switch self {
        case .thinking, .redactedThinking, .openAIReasoning: true
        case .text, .toolUse, .toolResult: false
        }
    }

    /// Completeness for the reasoning cases only. Text and tool blocks are complete by
    /// construction and are not reasoning, so they never gate the streaming indicator.
    static func isReasoningComplete(_ block: AgentContentBlock) -> Bool {
        switch block {
        case .thinking(_, let signature): !signature.isEmpty
        case .redactedThinking(let data): !data.isEmpty
        case .openAIReasoning(_, _, _, _, let reasoningComplete): reasoningComplete
        case .text, .toolUse, .toolResult: true
        }
    }
}

enum AgentContentBlock: Codable, Sendable {
    case thinking(text: String, signature: String)
    case redactedThinking(data: String)
    case openAIReasoning(
        summary: String,
        encryptedContent: String,
        itemID: String?,
        model: AgentModel,
        /// Set when the stream closed the reasoning item. Only `/v1/responses` sends
        /// `encrypted_content`; chat/completions reasoning is closed by the turn's stop
        /// event, so absence of that field must not mean "still streaming".
        isComplete: Bool
    )
    case text(String)
    case toolUse(id: String, name: String, inputJSON: String)
    case toolResult(toolUseId: String, content: [ToolResult.Block], isError: Bool)

    private enum Kind: String, Codable {
        case thinking, redactedThinking, openAIReasoning, text, toolUse, toolResult
    }
    private enum CodingKeys: String, CodingKey {
        case kind, text, signature, data, id, name, input, toolUseId, content, isError
        case summary, encryptedContent, itemID, model, isComplete
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
            let encryptedContent = try c.decode(String.self, forKey: .encryptedContent)
            self = .openAIReasoning(
                summary: try c.decode(String.self, forKey: .summary),
                encryptedContent: encryptedContent,
                itemID: try c.decodeIfPresent(String.self, forKey: .itemID),
                model: try c.decode(AgentModel.self, forKey: .model),
                // History written before this field existed is complete once it has content.
                isComplete: try c.decodeIfPresent(Bool.self, forKey: .isComplete)
                    ?? !encryptedContent.isEmpty
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
        case .openAIReasoning(let summary, let encryptedContent, let itemID, let model, let isComplete):
            try c.encode(Kind.openAIReasoning, forKey: .kind)
            try c.encode(summary, forKey: .summary)
            try c.encode(encryptedContent, forKey: .encryptedContent)
            try c.encodeIfPresent(itemID, forKey: .itemID)
            try c.encode(model, forKey: .model)
            try c.encode(isComplete, forKey: .isComplete)
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
