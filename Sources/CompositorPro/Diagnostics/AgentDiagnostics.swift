import Foundation

/// Traces an agent turn so a report can be turned into evidence.
///
/// Shapes only — never the prompt, never a credential. A request id ties the request, every
/// tool call and the terminal outcome of one turn together, which is the only way to read a
/// turn that interleaved with others.
enum AgentDiagnostics {
    /// Long enough that a slow model is not flagged, short enough to catch a wedge. A tool
    /// that never returns is the failure this exists for: without a threshold, a hung tool is
    /// only visible as an absence in the log.
    static let slowOperationSeconds: Double = 20

    static func beginTurn(id: String, settings: AgentRunSettings, messageCount: Int, toolCount: Int) {
        let model = settings.model
        var detail = "model=\(model.rawValue) provider=\(model.provider.rawValue)"
        if let custom = settings.custom {
            // The host and wire model are the only way to tell two custom entries apart.
            detail += " customHost=\(custom.baseURL.host ?? "?") customModel=\(custom.modelID)"
        }
        detail += " messages=\(messageCount) tools=\(toolCount)"
        Log.agent.info("chat turn begin id=\(id) \(detail) effort=\(settings.reasoningEffort.rawValue)")
        Log.agent.activity("agent turn \(id) streaming \(detail)")
    }


    /// The chat loop sets this for the duration of a turn so a transport-level failure can be
    /// attributed without threading a parameter through every client. Main-actor state, so the
    /// transport reads it at the point it already hops.
    @MainActor static var currentTurnID: String = "-"

    static func httpFailure(id: String, host: String, status: Int, body: String) {
        Log.agent.error(
            "chat turn \(id) http status=\(status) host=\(host) body=\(Self.snippet(body))",
            telemetry: "Agent chat HTTP failure",
            data: ["status": status, "host": host]
        )
    }

    static func turnFailed(id: String, stage: String, error: Error, elapsed: Double) {
        Log.agent.error(
            "chat turn \(id) failed stage=\(stage) after=\(Int(elapsed * 1000))ms error=\(Log.detail(error))",
            telemetry: "Agent chat turn failed",
            data: ["stage": stage]
        )
    }

    static func turnCompleted(id: String, turns: Int, elapsed: Double, stopReason: AgentStopReason) {
        Log.agent.info(
            "chat turn \(id) done apiCalls=\(turns) total=\(Int(elapsed * 1000))ms stop=\(stopReason.rawValue)"
        )
        Log.agent.activity("agent turn \(id) finished")
    }

    static func toolBegan(id: String, name: String) {
        Log.agent.activity("tool \(name) in flight (turn \(id))")
    }

    /// Warned rather than logged outright: per-tool success logging on every call is noise, but
    /// an operation that takes unexpectedly long is the one thing worth noticing.
    static func toolFinished(id: String, name: String, elapsed: Double, isError: Bool) {
        let ms = Int(elapsed * 1000)
        if isError {
            Log.agent.warning("tool \(name) failed turn=\(id) after=\(ms)ms")
        } else if elapsed >= slowOperationSeconds {
            Log.agent.warning(
                "tool \(name) slow turn=\(id) after=\(ms)ms — no progress was reported while it ran",
                telemetry: "Agent tool slow",
                data: ["tool": name, "ms": ms]
            )
        }
    }

    /// Truncates a response body: enough to see an error message, not enough to become the
    /// report. Gateways echo the request back in error payloads often enough to matter.
    static func snippet(_ body: String, limit: Int = 400) -> String {
        let collapsed = body
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit)) + "…"
    }
}
