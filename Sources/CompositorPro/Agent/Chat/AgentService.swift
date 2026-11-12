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

    /// Rolling summary of conversation turns older than the sliding window. Injected
    /// into the system prompt so old context stays relevant without replaying every turn.
    private var rollingSummary: String = ""

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
        didSet {
            cancel()
            toolExecutor = editor.map {
                ToolExecutor(editor: $0, skillStore: skillStore ?? .shared, userDefaults: userDefaults)
            }
        }
    }
    private var toolExecutor: ToolExecutor?
    @ObservationIgnored private var runTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var currentRunID: UUID?
    private static let streamTimeoutRetryLimit = 2
    private var drainsInProgress = 0

    private var currentTask: Task<Void, Never>? { currentRunID.flatMap { runTasks[$0] } }

    func loadSessions(from projectURL: URL?) async {
        cancel()
        sessions = ChatSessionStore.load(from: projectURL)
            .filter { !$0.messages.isEmpty }
            .map {
                var session = $0
                session.isOpen = false
                return session
            }
            .sorted { $0.updatedAt > $1.updatedAt }

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
        cancel()
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
        cancel()
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
            cancel()
            syncMessagesIntoCurrentSession()
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
        if currentSessionId == id { cancel() }
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
        guard drainsInProgress == 0 else { return }
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
        currentRunID = nil
        isStreaming = false
        syncMessagesIntoCurrentSession()
        onSessionsChanged?()
    }

    func cancelAndWait() async {
        drainsInProgress += 1
        defer { drainsInProgress -= 1 }
        let tasks = Array(runTasks.values)
        let conversationID = currentSessionId
        for task in tasks { task.cancel() }
        cancel()
        for task in tasks { await task.value }
        if currentRunID == nil, currentSessionId == conversationID {
            syncMessagesIntoCurrentSession()
            onSessionsChanged?()
        }
    }

    @discardableResult
    func kickOffStream(
        conversationID: UUID,
        traceID: UUID,
        settings: AgentRunSettings,
        client: (any AgentClient)? = nil
    ) -> Task<Void, Never> {
        guard drainsInProgress == 0 else { return Task {} }
        let previousTasks = Array(runTasks.values)
        for task in previousTasks { task.cancel() }
        cancel()
        let runID = UUID()
        currentRunID = runID
        isStreaming = true
        let task = Task { [weak self] in
            defer {
                self?.runTasks.removeValue(forKey: runID)
                if let self {
                    if self.currentSessionId == conversationID { self.syncMessagesIntoCurrentSession() }
                    self.onSessionsChanged?()
                }
                if let self, self.currentRunID == runID {
                    self.isStreaming = false
                    self.currentRunID = nil
                }
            }
            for previous in previousTasks { await previous.value }
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
            messageCount: messages.count,
            toolCount: ToolDefinitions.all.count
        )
        let selectedClient: (any AgentClient)?
        if let suppliedClient { selectedClient = suppliedClient }
        else { selectedClient = await selectClient(for: settings) }
        guard let client = selectedClient else {
            if isCurrentRun(runID, conversationID: conversationID, editor: runEditor) {
                streamError = .unavailable(chosenModel)
            }
            return
        }
        guard isCurrentRun(runID, conversationID: conversationID, editor: runEditor) else { return }
        let skillStore = skillStore ?? SkillStore.shared
        await skillStore.waitForSkillSync()
        if Task.isCancelled { return }
        await skillStore.reloadSkills()
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
        let contextIsTight = rollingSummary.utf16.count > 2_000 || messages.count > 40
        // A targeted edit (one clip, one property) pays only for editing schemas; production runs keep all.
        // A short follow-up ("yes, do it") continues the request it answers, so the whole
        // conversation decides: any earlier generative or production request keeps the full tool set.
        let userRequests = messages.compactMap { msg -> String? in
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

        loop: while isCurrentRun(runID, conversationID: conversationID, editor: runEditor) {
            resolveOrphanToolUses()
            let apiMsgs = await apiMessages()
            let delegationEnabled = await delegation.isEnabled
            let permitsFallback = await delegation.permitsFallback
            guard isCurrentRun(runID, conversationID: conversationID, editor: runEditor) else { break }

            // Tool pruning: targeted edits send only editing schemas; tight context also drops production tools.
            let tools: [AgentToolSchema]
            if targetedEdit {
                tools = baseTools.filter { editingSubset.contains($0.name) }
            } else if contextIsTight {
                tools = baseTools.filter { editingToolSet.contains($0.name) }
            } else {
                tools = baseTools
            }

            // Build system instructions: core + rolling summary + editing progress + delegation + skills.
            var systemParts: [String] = []
            systemParts.append(targetedEdit
                ? AgentInstructions.targetedEditInstructions
                : AgentInstructions.serverInstructions)

            if !rollingSummary.isEmpty {
                systemParts.append("\n\n# Rolling summary of earlier turns\n\(rollingSummary)")
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

            guard let inputMessageID = messages.last(where: { $0.role == .user })?.id else {
                streamError = .upstream("The agent request has no user message.")
                break loop
            }
            let assistant = AgentMessage(role: .assistant, blocks: [])
            messages.append(assistant)
            let assistantID = assistant.id

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
                    await self?.applyStreamSnapshot(
                        snapshot,
                        assistantID: assistantID,
                        conversationID: conversationID
                    )
                }
                let stopReason = finalSnapshot.stopReason
                streamTimeoutRetries = 0

                dropEmptyAssistantTurn(id: assistantID, conversationID: conversationID)
                // Common progress file is the single source of truth a new chat loads to resume.
                refreshEditingProgress()
                guard isCurrentRun(runID, conversationID: conversationID, editor: runEditor) else { break }
                if stopReason == .refusal {
                    streamError = .refusal(chosenModel)
                    break loop
                }
                if stopReason == .maxTokens && streamTimeoutRetries < 2 {
                    streamTimeoutRetries += 1
                    Log.agent.notice("chat stream turn=\(turnID) continued after output truncation retry=\(streamTimeoutRetries)")
                    messages.append(AgentMessage(role: .user, blocks: [.text("Continue previous response.")]))
                    continue loop
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
                    Log.agent.notice("chat turn=\(turnID) context-length exceeded; compressing and retrying")
                    messages = Self.compressMessagesForContext(messages, keepLastTurns: 2)
                    rollingSummary = ""
                    continue loop
                }

                if contextExceeded {
                    streamError = .upstream("Context length exceeded: the conversation is too long for this model. Start a new chat to continue editing from the saved progress file.")
                    break loop
                }

                if timedOut {
                    discardAssistantTurn(id: assistantID, conversationID: conversationID)
                } else {
                    dropEmptyAssistantTurn(id: assistantID, conversationID: conversationID)
                }
                guard isCurrentRun(runID, conversationID: conversationID, editor: runEditor),
                      !(error is CancellationError), AgentHTTP.urlErrorCode(error) != .cancelled
                else { break loop }
                if timedOut, streamTimeoutRetries < Self.streamTimeoutRetryLimit {
                    streamTimeoutRetries += 1
                    Log.agent.notice("chat stream retry id=\(turnID) reason=timeout retry=\(streamTimeoutRetries)/\(Self.streamTimeoutRetryLimit)")
                    continue loop
                }
                streamError = (error as? AgentServiceError) ?? .upstream(error.localizedDescription)
                break loop
            }
        }
    }

    private func assistantMessageIndex(id: UUID) -> Int? {
        messages.firstIndex { $0.id == id && $0.role == .assistant }
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
        if currentSessionId == conversationID {
            guard let index = assistantMessageIndex(id: id) else { return }
            messages.remove(at: index)
            return
        }
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: {
                  $0.id == id && $0.role == .assistant
              }) else { return }
        sessions[sessionIndex].messages.remove(at: messageIndex)
        sessions[sessionIndex].updatedAt = Date()
    }

    func dropEmptyAssistantTurn(id: UUID) {
        guard let index = assistantMessageIndex(id: id) else { return }
        messages[index].blocks.removeAll { !Self.isComplete($0) }
        guard messages[index].blocks.isEmpty else { return }
        messages.remove(at: index)
    }

    func applyStreamSnapshot(
        _ snapshot: AgentStreamSnapshot,
        assistantID: UUID,
        conversationID: UUID
    ) {
        if currentSessionId == conversationID {
            guard let index = assistantMessageIndex(id: assistantID) else { return }
            messages[index].blocks = snapshot.blocks
            return
        }

        guard let sessionIndex = sessions.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: {
                  $0.id == assistantID && $0.role == .assistant
              }) else { return }
        sessions[sessionIndex].messages[messageIndex].blocks = snapshot.blocks
        sessions[sessionIndex].updatedAt = Date()
    }

    private func dropEmptyAssistantTurn(id: UUID, conversationID: UUID) {
        guard currentSessionId != conversationID else {
            dropEmptyAssistantTurn(id: id)
            return
        }
        guard let sessionIndex = sessions.firstIndex(where: { $0.id == conversationID }),
              let messageIndex = sessions[sessionIndex].messages.firstIndex(where: {
                  $0.id == id && $0.role == .assistant
              }) else { return }
        sessions[sessionIndex].messages[messageIndex].blocks.removeAll { !Self.isComplete($0) }
        if sessions[sessionIndex].messages[messageIndex].blocks.isEmpty {
            sessions[sessionIndex].messages.remove(at: messageIndex)
        }
        sessions[sessionIndex].updatedAt = Date()
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
        !Task.isCancelled && currentRunID == runID && currentSessionId == conversationID && editor === runEditor
    }

    private func runPendingToolUses(assistantID: UUID, conversationID: UUID, runID: UUID,
                                   runEditor: EditorViewModel?, settings: AgentRunSettings,
                                   client: any AgentClient, traceID: UUID, delegation: AgentDelegation) async {
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
            if !isCurrentRun(runID, conversationID: conversationID, editor: runEditor) {
                resultBlocks.append(.toolResult(toolUseId: use.id, content: [.text("Cancelled")], isError: true))
                continue
            }
            let result: ToolResult
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
        }
        appendToolResults(resultBlocks, conversationID: conversationID)
        // Persist editing progress after each batch of tool results so a new chat can
        // resume without replaying full history.
        refreshEditingProgress()
    }

    func appendToolResults(_ blocks: [AgentContentBlock], conversationID: UUID) {
        guard !blocks.isEmpty else { return }
        let message = AgentMessage(role: .user, blocks: blocks)
        if currentSessionId == conversationID {
            messages.append(message)
        } else if let index = sessions.firstIndex(where: { $0.id == conversationID }) {
            sessions[index].messages.append(message)
            sessions[index].updatedAt = Date()
            onSessionsChanged?()
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
    private func apiMessages() async -> [AgentRequestMessage] {
        var result: [AgentRequestMessage] = []
        let lastUserIndex = messages.lastIndex(where: { $0.role == .user })

        // Build the rolling summary from turns outside the sliding window.
        let windowStart = lastUserIndex.map { max(0, $0 - 6) } ?? 0
        var summaryParts: [String] = []

        for (index, msg) in messages.enumerated() {
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
            rollingSummary = summaryParts.joined(separator: " ")
        } else {
            rollingSummary = ""
        }

        // Enforce token budget: estimate total input, prune oldest assistant turns first.
        let systemTokens = 0
        var messageTokens = 0
        for msg in result {
            messageTokens += msg.content.reduce(0) { $0 + Self.estimateTokens(blockText($1)) }
        }
        let totalTokens = systemTokens + messageTokens + Self.estimateTokens(rollingSummary)

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
