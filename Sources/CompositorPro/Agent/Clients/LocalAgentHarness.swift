import Foundation

enum LocalAgentHarness: String, CaseIterable, Identifiable, Sendable {
    case codex
    case claudeCode
    case antigravity

    var id: String { rawValue }

    var name: String {
        switch self {
        case .codex: "Codex"
        case .claudeCode: "Claude Code"
        case .antigravity: "Antigravity"
        }
    }

    var executableName: String {
        switch self {
        case .codex: "codex"
        case .claudeCode: "claude"
        case .antigravity: "agy"
        }
    }

    var signInCommand: String {
        switch self {
        case .codex: "codex login"
        case .claudeCode: "claude auth login"
        case .antigravity: "agy"
        }
    }

    var installCommand: String {
        switch self {
        case .codex: "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
        case .claudeCode: "curl -fsSL https://claude.ai/install.sh | bash"
        case .antigravity: "curl -fsSL https://antigravity.google/cli/install.sh | bash"
        }
    }

    var documentationURL: URL {
        switch self {
        case .codex: URL(string: "https://developers.openai.com/codex/noninteractive")!
        case .claudeCode: URL(string: "https://code.claude.com/docs/en/headless")!
        case .antigravity: URL(string: "https://antigravity.google/docs/cli/headless/")!
        }
    }

    @concurrent
    static func discoverExecutables(
        home: URL? = nil,
        path: String? = nil
    ) async -> [Self: URL] {
        let home = home ?? FileManager.default.homeDirectoryForCurrentUser
        let path = path ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let directories = [home.appendingPathComponent(".local/bin"),
                           home.appendingPathComponent(".codex/bin"),
                           URL(fileURLWithPath: "/opt/homebrew/bin"),
                           URL(fileURLWithPath: "/usr/local/bin")]
            + path.split(separator: ":").filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: String($0)) }
        var installed: [Self: URL] = [:]
        for harness in allCases {
            guard !Task.isCancelled else { return [:] }
            installed[harness] = directories.map { $0.appendingPathComponent(harness.executableName) }
                .first { FileManager.default.isExecutableFile(atPath: $0.path) }
        }
        return installed
    }

    static func normalizedModelID(_ value: String) throws -> String? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 256, !value.hasPrefix("-"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LocalAgentFailure.invalidInput
        }
        return value.isEmpty ? nil : value
    }
}

enum LocalAgentFailure: Error, Equatable, Sendable {
    case notInstalled(LocalAgentHarness)
    case signInRequired(LocalAgentHarness)
    case permissionRequired(LocalAgentHarness)
    case runFailed(LocalAgentHarness, Int32)
    case launchFailed(LocalAgentHarness)
    case invalidOutput
    case incompleteOutput
    case outputLimit
    case invalidInput
    case setupFailed
    case cleanupFailed
    indirect case cleanupAfterFailure(LocalAgentFailure)
    case cancelled
    case timedOut

    @MainActor var displayMessage: String {
        switch self {
        case .notInstalled(let harness):
            L10n.string("Install the \(harness.name) CLI from Connect agent, then try again.")
        case .signInRequired(let harness):
            L10n.string("Sign in once using \(harness.signInCommand) in Terminal, then send your request here.")
        case .permissionRequired(let harness):
            L10n.string("\(harness.name) needs permission for this request. Review its CLI permissions, then try again.")
        case .runFailed(let harness, let code):
            L10n.string("\(harness.name) stopped with status \(code). Run \(harness.executableName) in Terminal to check your account and model, then try again.")
        case .launchFailed(let harness):
            L10n.string("Could not launch \(harness.name). Check its CLI installation, then try again.")
        case .invalidOutput:
            L10n.string("The agent returned an unsupported response. Update its CLI, then try again.")
        case .incompleteOutput:
            L10n.string("The agent stopped before finishing its response. Check its CLI, then try again.")
        case .outputLimit:
            L10n.string("The agent response exceeded the size limit. Ask for a smaller task.")
        case .invalidInput:
            L10n.string("The request contains unsupported or oversized content. Start a smaller chat and try again.")
        case .setupFailed:
            L10n.string("Could not prepare the agent workspace. Check temporary storage and try again.")
        case .cleanupFailed:
            L10n.string("Could not remove the temporary agent workspace. Check temporary storage.")
        case .cleanupAfterFailure(let failure):
            failure.displayMessage + " " + L10n.string("Temporary workspace cleanup also failed.")
        case .cancelled:
            L10n.string("Agent request canceled.")
        case .timedOut:
            L10n.string("The agent stopped after 2 hours without an update. Check the project before continuing; earlier edits may already be applied.")
        }
    }
}

extension LocalAgentFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notInstalled(let harness): "local_agent_not_installed: \(harness.rawValue)"
        case .signInRequired(let harness): "local_agent_sign_in_required: \(harness.rawValue)"
        case .permissionRequired(let harness): "local_agent_permission_required: \(harness.rawValue)"
        case .runFailed(let harness, let status): "local_agent_failed: \(harness.rawValue) status=\(status)"
        case .launchFailed(let harness): "local_agent_launch_failed: \(harness.rawValue)"
        case .invalidOutput: "local_agent_invalid_output"
        case .incompleteOutput: "local_agent_incomplete_output"
        case .outputLimit: "local_agent_output_limit"
        case .invalidInput: "local_agent_invalid_input"
        case .setupFailed: "local_agent_workspace_failed"
        case .cleanupFailed: "local_agent_cleanup_failed"
        case .cleanupAfterFailure(let failure): "local_agent_cleanup_failed after=\(failure.errorDescription ?? "local_agent_failed")"
        case .cancelled: "local_agent_canceled"
        case .timedOut: "local_agent_timed_out"
        }
    }
}
