import Foundation

struct LocalAgentClient: AgentClient {
    static let runGate = AsyncSemaphore(value: 2)
    let harness: LocalAgentHarness
    let executable: URL
    let effort: AgentReasoningEffort
    let endpoint: URL
    var modelID: String? = nil

    func stream(system: String, tools: [AgentToolSchema], messages: [AgentRequestMessage],
                context: AgentRequestContext) -> AgentStreamOperation {
        makeAgentStream { continuation in
            let request = try await LocalAgentRequest.prepare(
                harness: harness, effort: effort, system: system, messages: messages, endpoint: endpoint, modelID: modelID
            )
            let decoder = LocalAgentStreamDecoder(harness: harness)
            do {
                let result = try await LocalAgentProcess.run(executable: executable, request: request) { line in
                    for event in try await decoder.receive(line) { continuation.yield(event) }
                }
                try await decoder.finish(status: result.status, diagnostics: result.diagnostics)
            } catch {
                let failure = (error as? LocalAgentFailure) ?? (error is CancellationError ? .cancelled : .launchFailed(harness))
                do { try await request.cleanup() }
                catch { throw LocalAgentFailure.cleanupAfterFailure(failure) }
                if error is CancellationError || error is LocalAgentFailure { throw error }
                throw LocalAgentFailure.launchFailed(harness)
            }
            try await request.cleanup()
            try Task.checkCancellation()
            continuation.yield(.messageStop(stopReason: .endTurn))
        }
    }
}

actor LocalAgentStreamDecoder {
    private let harness: LocalAgentHarness
    private var complete = false
    private var hasText = false
    private var claudeMessageStreamed = false
    private var codexItems: [String: String] = [:]

    init(harness: LocalAgentHarness) { self.harness = harness }

    func receive(_ line: Data) throws -> [AgentStreamEvent] {
        guard !complete else { return [] }
        let json: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw LocalAgentFailure.invalidOutput
            }
            json = object
        } catch { throw LocalAgentFailure.invalidOutput }
        let events: [AgentStreamEvent]
        switch harness {
        case .antigravity: events = try antigravity(json)
        case .claudeCode: events = try claude(json)
        case .codex: events = try codex(json)
        }
        if events.contains(where: { if case .textDelta(let text) = $0 { return !text.isEmpty }; return false }) {
            hasText = true
        }
        return events
    }

    func finish(status: Int32, diagnostics: String) throws {
        if let failure = Self.classifiedFailure(diagnostics, harness: harness) { throw failure }
        guard status == 0 else { throw LocalAgentFailure.runFailed(harness, status) }
        guard complete, hasText else { throw LocalAgentFailure.incompleteOutput }
    }

    private func antigravity(_ json: [String: Any]) throws -> [AgentStreamEvent] {
        switch json["event"] as? String {
        case "init": return [.activity(.connected)]
        case "step_update":
            guard let step = json["step_update"] as? [String: Any] else { throw LocalAgentFailure.invalidOutput }
            switch step["step_type"] as? String {
            case "agent_response":
                if let text = step["text_delta"] as? String, !text.isEmpty { return [.textDelta(text)] }
                return [.activity(.reasoning)]
            case "tool_call", "mcp_tool_call", "tool": return [.activity(.preparingTool("compositor-pro"))]
            default: return []
            }
        case "result":
            guard let result = json["result"] as? [String: Any], let status = result["status"] as? String else {
                throw LocalAgentFailure.invalidOutput
            }
            if status == "CANCELED" || status == "INTERRUPTED" { throw CancellationError() }
            if status == "WAITING" { throw LocalAgentFailure.permissionRequired(harness) }
            guard status == "SUCCESS" else {
                throw Self.classifiedFailure(result["error"] as? String ?? "", harness: harness)
                    ?? LocalAgentFailure.runFailed(harness, 1)
            }
            complete = true
            return finalText(result["response"] as? String)
        default: return []
        }
    }

    private func claude(_ json: [String: Any]) throws -> [AgentStreamEvent] {
        if json["parent_tool_use_id"] is String { return [] }
        switch json["type"] as? String {
        case "system": return [.activity(.connected)]
        case "stream_event":
            guard let event = json["event"] as? [String: Any] else { throw LocalAgentFailure.invalidOutput }
            switch event["type"] as? String {
            case "message_start": claudeMessageStreamed = false
            case "content_block_start":
                if let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use" {
                    return [.activity(.preparingTool(block["name"] as? String ?? "compositor-pro"))]
                }
            case "content_block_delta":
                if let delta = event["delta"] as? [String: Any] {
                    if delta["type"] as? String == "text_delta", let text = delta["text"] as? String, !text.isEmpty {
                        claudeMessageStreamed = true
                        return [.textDelta(text)]
                    }
                    if delta["type"] as? String == "thinking_delta" { return [.activity(.reasoning)] }
                }
            default: break
            }
            return []
        case "assistant":
            guard !claudeMessageStreamed, let message = json["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]] else { return [] }
            return blocks.compactMap { block in
                guard block["type"] as? String == "text", let text = block["text"] as? String, !text.isEmpty else { return nil }
                return .textDelta(text)
            }
        case "result":
            guard json["is_error"] as? Bool != true, json["subtype"] as? String == "success" else {
                throw Self.classifiedFailure(json["result"] as? String ?? "", harness: harness)
                    ?? LocalAgentFailure.runFailed(harness, 1)
            }
            if let denials = json["permission_denials"] as? [Any], !denials.isEmpty {
                throw LocalAgentFailure.permissionRequired(harness)
            }
            complete = true
            return finalText(json["result"] as? String)
        default: return []
        }
    }

    private func codex(_ json: [String: Any]) throws -> [AgentStreamEvent] {
        switch json["type"] as? String {
        case "thread.started", "turn.started": return [.activity(.connected)]
        case "item.started", "item.updated", "item.completed":
            guard let item = json["item"] as? [String: Any] else { throw LocalAgentFailure.invalidOutput }
            switch item["type"] as? String {
            case "agent_message":
                guard let id = item["id"] as? String, let text = item["text"] as? String,
                      codexItems.count < 4096 else { throw LocalAgentFailure.invalidOutput }
                let previous = codexItems[id] ?? ""
                guard text.hasPrefix(previous) else { throw LocalAgentFailure.invalidOutput }
                codexItems[id] = text
                let delta = String(text.dropFirst(previous.count))
                return delta.isEmpty ? [] : [.textDelta(delta)]
            case "mcp_tool_call": return [.activity(.preparingTool(item["tool"] as? String ?? "compositor-pro"))]
            case "reasoning": return [.activity(.reasoning)]
            default: return []
            }
        case "turn.completed": complete = true; return []
        case "turn.failed", "error":
            let error = json["error"] as? [String: Any]
            throw Self.classifiedFailure(error?["message"] as? String ?? json["message"] as? String ?? "", harness: harness)
                ?? LocalAgentFailure.runFailed(harness, 1)
        default: return []
        }
    }

    private func finalText(_ text: String?) -> [AgentStreamEvent] {
        guard !hasText, let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return [.textDelta(text)]
    }

    private static func classifiedFailure(_ message: String, harness: LocalAgentHarness) -> LocalAgentFailure? {
        let message = message.lowercased()
        if ["authentication required", "not authenticated", "not logged in", "please sign in", "login required", "invalid api key"]
            .contains(where: message.contains) { return .signInRequired(harness) }
        if ["permission denied", "soft-denied", "requires approval", "permission notice", "permission_denied"]
            .contains(where: message.contains) { return .permissionRequired(harness) }
        return nil
    }
}
