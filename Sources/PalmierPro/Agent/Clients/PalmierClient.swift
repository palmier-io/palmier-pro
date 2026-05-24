import Foundation
import ClerkKit

struct PalmierClient: AgentClient {
    let model: AnthropicModel
    var maxTokens: Int = 8192

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(system: system, tools: tools, messages: messages, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage],
        continuation: AsyncThrowingStream<AnthropicStreamEvent, Error>.Continuation
    ) async throws {
        guard let baseURL = BackendConfig.convexHttpURL else {
            throw PalmierClientError.upstream("Backend not configured")
        }
        let endpoint = baseURL.appendingPathComponent("v1/agent/stream")

        guard let session = await Clerk.shared.session, session.status == .active else {
            throw PalmierClientError.unauthenticated
        }
        guard let jwt = try await session.getToken(), !jwt.isEmpty else {
            throw PalmierClientError.unauthenticated
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: AnthropicRequestBody.build(
            model: model, maxTokens: maxTokens, system: system, tools: tools, messages: messages
        ))

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            var body = ""
            for try await line in bytes.lines { body += line + "\n" }
            throw PalmierClientError.from(status: http.statusCode, body: body)
        }

        try await AnthropicSSE.parse(bytes: bytes, continuation: continuation)
    }
}

enum PalmierClientError: LocalizedError {
    case unauthenticated
    case insufficientCredits(String)
    case upstream(String)

    var errorDescription: String? {
        switch self {
        case .unauthenticated: "Sign in to use the AI agent."
        case .insufficientCredits(let m): m
        case .upstream(let m): m
        }
    }

    static func from(status: Int, body: String) -> PalmierClientError {
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
