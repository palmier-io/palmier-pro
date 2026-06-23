import Foundation
import Observation

/// Bridges the rest of the app to the embedded Claude Code terminal. The terminal
/// itself (see `AgentTerminalView`) owns the `claude` process; this type forwards
/// prompts and @-references into it, and keeps the per-project chat-session list
/// the project document still snapshots.
@Observable
@MainActor
final class AgentService {

    weak var editor: EditorViewModel?

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
    var onSessionsChanged: (@MainActor () -> Void)?

    /// Set by the terminal view: types text into the live `claude` PTY.
    @ObservationIgnored var terminalTyper: ((String) -> Void)? {
        didSet { flushPending() }
    }
    /// Set by the terminal view: tears down and restarts the `claude` session.
    @ObservationIgnored var restartTerminal: (() -> Void)?

    /// Buffer text typed before the terminal mounted (e.g. a media-panel hand-off
    /// that opens the panel), then flush once the typer is connected.
    @ObservationIgnored private var pendingType: String?

    func loadSessions(from projectURL: URL?) {
        sessions = ChatSessionStore.load(from: projectURL)
            .filter { !$0.messages.isEmpty }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Terminal hand-off

    func reveal() { editor?.agentPanelVisible = true }

    /// Reveal the panel and type `text` into the Claude Code terminal (no Return —
    /// the user reviews and sends).
    func type(_ text: String) {
        reveal()
        if let typer = terminalTyper {
            typer(text)
        } else {
            pendingType = (pendingType ?? "") + text
        }
    }

    func seedPrompt(_ prompt: String) { type(prompt) }

    private func flushPending() {
        guard let typer = terminalTyper, let pending = pendingType else { return }
        pendingType = nil
        typer(pending)
    }

    // MARK: - @-references from the editor

    func attachMention(for asset: MediaAsset) {
        type("\(asset.mentionDisplayName) ")
    }

    func attachMentions(forClipIds clipIds: [String]) {
        guard !clipIds.isEmpty else { return }
        type("clips \(clipIds.joined(separator: ", ")) ")
    }

    func attachSelectedTimelineRangeMention() {
        guard let editor, let range = editor.validSelectedTimelineRange else { return }
        let mention = AgentTimelineRangeMention(range: range, fps: editor.timeline.fps)
        type("the timeline range \(mention.startTimecode)\u{2013}\(mention.endTimecode) ")
    }
}

// Persisted chat-session shape. Retained so the project document keeps
// snapshotting/reading existing `chat/*.json` files; the embedded terminal keeps
// its own history under ~/.claude.

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
