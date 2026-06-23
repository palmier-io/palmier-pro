import Foundation

/// Models offered for the embedded Claude Code session (passed via `--model`).
enum AnthropicModel: String, CaseIterable, Sendable {
    case opus48 = "claude-opus-4-8"
    case sonnet46 = "claude-sonnet-4-6"
    case haiku45 = "claude-haiku-4-5-20251001"

    var displayName: String {
        switch self {
        case .opus48: "Opus 4.8"
        case .sonnet46: "Sonnet 4.6"
        case .haiku45: "Haiku 4.5"
        }
    }
}
