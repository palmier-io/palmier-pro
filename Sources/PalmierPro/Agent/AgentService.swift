import Foundation
import Observation

@Observable
@MainActor
final class AgentService {

    private var apiKey: String = AnthropicKeychain.load() ?? ""

    var hasApiKey: Bool { !apiKey.isEmpty }

    var maskedApiKey: String {
        guard apiKey.count > 6 else { return String(repeating: "\u{2022}", count: apiKey.count) }
        return apiKey.prefix(3) + String(repeating: "\u{2022}", count: apiKey.count - 6) + apiKey.suffix(3)
    }

    func setApiKey(_ key: String) {
        AnthropicKeychain.save(key)
        apiKey = key
    }

    func removeApiKey() {
        AnthropicKeychain.delete()
        apiKey = ""
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
    var streamError: String?
    var onSessionsChanged: (@MainActor () -> Void)?

    weak var editor: EditorViewModel? {
        didSet { toolExecutor = editor.map { ToolExecutor(editor: $0) } }
    }
    private var toolExecutor: ToolExecutor?
    private var currentTask: Task<Void, Never>?

    func loadSessions(from projectURL: URL?) {
        sessions = ChatSessionStore.load(from: projectURL).sorted { $0.updatedAt > $1.updatedAt }
        if let first = sessions.first {
            currentSessionId = first.id
            messages = first.messages
        } else {
            let session = ChatSession()
            sessions = [session]
            currentSessionId = session.id
            messages = []
        }
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
        guard hasApiKey else {
            streamError = "No Anthropic API key is set."
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        messages.append(AgentMessage(role: .user, blocks: [.text(trimmed)], mentions: mentions))
        streamError = nil
        kickOffStream()
    }

    func clearConversation() {
        currentTask?.cancel()
        currentTask = nil
        messages = []
        isStreaming = false
        streamError = nil
        syncMessagesIntoCurrentSession()
        onSessionsChanged?()
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
        let client = AnthropicClient(apiKey: apiKey, model: model)
        let tools = ToolDefinitions.all.map {
            AnthropicToolSchema(name: $0.name.rawValue, description: $0.description, inputSchema: $0.inputSchema)
        }

        loop: while !Task.isCancelled {
            let apiMsgs = apiMessages()
            messages.append(AgentMessage(role: .assistant, blocks: []))
            let assistantIndex = messages.count - 1

            do {
                let stream = client.stream(
                    system: AgentInstructions.serverInstructions,
                    tools: tools,
                    messages: apiMsgs
                )

                var stopReason: AnthropicStopReason = .endTurn

                for try await event in stream {
                    try Task.checkCancellation()
                    switch event {
                    case .textDelta(let chunk):
                        appendTextDelta(chunk, toAssistantAt: assistantIndex)
                    case .toolUseComplete(let id, let name, let inputJSON):
                        messages[assistantIndex].blocks.append(
                            .toolUse(id: id, name: name, inputJSON: inputJSON)
                        )
                    case .messageStop(let reason):
                        stopReason = reason
                    }
                }

                if stopReason == .toolUse {
                    await runPendingToolUses(assistantIndex: assistantIndex)
                    continue loop
                }
                break loop
            } catch is CancellationError {
                break loop
            } catch {
                streamError = error.localizedDescription
                break loop
            }
        }
    }

    private func appendTextDelta(_ chunk: String, toAssistantAt index: Int) {
        guard messages.indices.contains(index) else { return }
        if case .text(let existing)? = messages[index].blocks.last {
            messages[index].blocks[messages[index].blocks.count - 1] = .text(existing + chunk)
        } else {
            messages[index].blocks.append(.text(chunk))
        }
    }

    private func runPendingToolUses(assistantIndex: Int) async {
        guard messages.indices.contains(assistantIndex) else { return }
        guard let executor = toolExecutor else {
            messages.append(AgentMessage(role: .user, blocks: [.text("Tool executor unavailable.")]))
            return
        }

        var resultBlocks: [AgentContentBlock] = []
        for block in messages[assistantIndex].blocks {
            guard case let .toolUse(id, name, inputJSON) = block else { continue }
            let result = await executor.execute(name: name, args: Self.parseJSONObject(inputJSON))
            resultBlocks.append(.toolResult(toolUseId: id, content: result.content, isError: result.isError))
        }
        if !resultBlocks.isEmpty {
            messages.append(AgentMessage(role: .user, blocks: resultBlocks))
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

    private func apiMessages() -> [AnthropicMessage] {
        messages.compactMap { msg in
            var content = msg.blocks.compactMap(Self.contentBlockJSON)
            if msg.role == .user, !msg.mentions.isEmpty {
                content.insert(["type": "text", "text": Self.mentionHint(msg.mentions)], at: 0)
            }
            guard !content.isEmpty else { return nil }
            return AnthropicMessage(role: msg.role == .user ? .user : .assistant, content: content)
        }
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

    private static func mentionHint(_ mentions: [AgentMention]) -> String {
        let entries: [[String: Any]] = mentions.map {
            ["mention": "@\($0.displayName)", "mediaRef": $0.mediaRef, "type": $0.type.rawValue]
        }
        let data = (try? JSONSerialization.data(withJSONObject: entries)) ?? Data()
        let json = String(data: data, encoding: .utf8) ?? "[]"
        return "Referenced assets in this message: \(json)"
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

    init(id: UUID = UUID(), role: Role, blocks: [AgentContentBlock], mentions: [AgentMention] = []) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.mentions = mentions
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

struct AgentMention: Identifiable, Hashable, Codable {
    let id: UUID
    let displayName: String
    let mediaRef: String
    let type: ClipType

    init(id: UUID = UUID(), displayName: String, mediaRef: String, type: ClipType) {
        self.id = id
        self.displayName = displayName
        self.mediaRef = mediaRef
        self.type = type
    }
}

