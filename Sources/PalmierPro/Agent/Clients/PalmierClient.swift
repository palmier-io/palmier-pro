import Foundation
import ClerkKit

struct PalmierClient: AgentClient {
    let settings: AgentRunSettings

    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage],
        context: AgentRequestContext
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        makeAgentStream { continuation in
            try await run(
                system: system,
                tools: tools,
                messages: messages,
                context: context,
                continuation: continuation
            )
        }
    }

    private func run(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage],
        context: AgentRequestContext,
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        guard let baseURL = BackendConfig.convexHttpURL else {
            throw AgentServiceError.upstream("Backend not configured")
        }
        let endpoint = baseURL.appendingPathComponent("v1/agent/stream")

        guard let session = await Clerk.shared.session, session.status == .active else {
            throw AgentServiceError.unauthenticated
        }
        guard let jwt = try await session.getToken(), !jwt.isEmpty else {
            throw AgentServiceError.unauthenticated
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        context.apply(to: &request, telemetryEnabled: Analytics.isEnabled)
        request.httpBody = try JSONSerialization.data(
            withJSONObject: settings.requestBody(system: system, tools: tools, messages: messages),
            options: [.sortedKeys]
        )

        let bytes = try await AgentHTTP.bytes(for: request) { status, body in
            AgentServiceError.from(status: status, body: body)
        }
        try await settings.model.provider.parseSSE(bytes: bytes, continuation: continuation)
    }
}

enum AgentServiceError: Error {
    case unauthenticated
    case insufficientCredits(String)
    case unavailable(AgentModel)
    case refusal(AgentModel)
    case upstream(String)

    static func from(status: Int, body: String) -> AgentServiceError {
        let parsed = parseErrorEnvelope(body)
        let message = parsed?.message ?? body.prefix(500).description
        switch parsed?.code {
        case "unauthenticated": return .unauthenticated
        case "insufficient_credits": return .insufficientCredits(message)
        default:
            if status == 401 { return .unauthenticated }
            if status == 402 { return .insufficientCredits(message) }
            return .upstream(message.isEmpty ? "HTTP \(status)" : message)
        }
    }

    private static func parseErrorEnvelope(_ body: String) -> (code: String, message: String)? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any],
              let code = err["code"] as? String,
              let message = err["message"] as? String
        else { return nil }
        return (code, message)
    }
}
