import Foundation

enum UserFacingError {
    static func message(_ raw: String) -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            return "Something went wrong. Try again."
        }
        if text.contains("UniFFI.ClientError.InternalError")
            || text.localizedCaseInsensitiveContains("channel closed") {
            return "Palmier backend is unavailable. Check backend configuration or try again."
        }
        if text.contains("codex_features")
            || text.contains("codex_rollout")
            || text.localizedCaseInsensitiveContains("ghost_commit") {
            return "Codex CLI returned local warnings. Try again, or run Codex once outside Palmier."
        }
        return text
    }
}
