import Foundation

extension ToolExecutor {
    // send_feedback's diagnostics trail + per-session dedupe; recorded centrally in execute().
    struct FeedbackState {
        private(set) var recentTools: [String] = []
        private(set) var lastError: String?
        var sentKeys: Set<String> = []

        mutating func record(_ result: ToolResult, for tool: ToolName) {
            guard tool != .sendFeedback else { return }
            recentTools.append(tool.rawValue)
            if recentTools.count > 15 { recentTools.removeFirst() }
            if result.isError, case let .text(message)? = result.content.first { lastError = message }
        }
    }

    func resetFeedbackState() { feedbackState = FeedbackState() }

    private static let feedbackCategories: Set<String> = [
        "missing_capability", "wrong_result", "confusing_ux", "failure", "suggestion",
    ]
    private static let feedbackSeverities: Set<String> = ["low", "medium", "high"]
    private static let maxFeedbackPerSession = 8

    func sendFeedback(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let category = try args.requireString("category").trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.feedbackCategories.contains(category) else {
            throw ToolError("Invalid category '\(category)'. Expected one of: \(Self.feedbackCategories.sorted().joined(separator: ", ")).")
        }
        let summary = try args.requireString("summary").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw ToolError("summary must not be empty.") }
        let details = args.string("details")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let severity = args.string("severity")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let severity, !Self.feedbackSeverities.contains(severity) {
            throw ToolError("Invalid severity '\(severity)'. Expected low, medium, or high.")
        }

        let dedupeKey = "\(category)|\(summary)"
        guard !feedbackState.sentKeys.contains(dedupeKey) else {
            return .ok("Already flagged this to the team this session — not sending a duplicate.")
        }
        guard feedbackState.sentKeys.count < Self.maxFeedbackPerSession else {
            return .ok("Feedback limit reached for this session. Summarize any remaining issues to the user instead of sending more.")
        }

        // Line 1 (tag + summary) becomes the email subject; category/severity stay in the body.
        var lines = ["[Agent] \(summary)"]
        var classification = "Category: \(category)"
        if let severity { classification += " · \(severity)" }
        lines += ["", classification]
        if let details, !details.isEmpty {
            lines += ["", "Details:", details]
        }
        lines += ["", "Diagnostics (auto-collected):"]
        lines.append("- Recent tools: \(feedbackState.recentTools.isEmpty ? "none" : feedbackState.recentTools.joined(separator: ", "))")
        lines.append("- Last error: \(feedbackState.lastError ?? "none")")
        if let projectId = editor.projectId {
            lines.append("- Project: \(projectId.prefix(8))")
        }

        do {
            try await AccountService.shared.sendFeedback(
                message: lines.joined(separator: "\n"),
                email: nil,
                mayContact: false,
                screenshotPngBase64: nil,
                appVersion: Self.appVersion,
                osVersion: Self.osVersion
            )
        } catch {
            return .error("Couldn't send feedback: \(error.localizedDescription)")
        }
        feedbackState.sentKeys.insert(dedupeKey)
        return .ok("Flagged this to the Palmier team. Thanks — this helps us improve the agent.")
    }

    private static var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}
