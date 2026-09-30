import Foundation

struct BYOKClient: AgentClient {
    let apiKey: String
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
                continuation: continuation
            )
        }
    }

    private func run(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentRequestMessage],
        continuation: AsyncThrowingStream<AgentStreamEvent, Error>.Continuation
    ) async throws {
        let provider = settings.model.provider
        if apiKey.isEmpty {
            // Loopback servers run keyless; everything else must present a credential.
            guard let endpoint = settings.custom, endpoint.allowsMissingAPIKey else {
                throw AgentClientTransportError.missingAPIKey(provider)
            }
        }

        var request = URLRequest(url: try endpoint())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        switch provider {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI, .custom:
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: settings.requestBody(system: system, tools: tools, messages: messages),
            options: [.sortedKeys]
        )

        let bytes = try await AgentHTTP.bytes(for: request) { status, body in
            AgentClientTransportError.httpError(provider: provider, status: status, body: body)
        }
        try await provider.parseSSE(bytes: bytes, continuation: continuation)
    }

    private func endpoint() throws -> URL {
        switch settings.model.provider {
        case .anthropic:
            return URL(string: "https://api.anthropic.com/v1/messages")!
        case .openAI:
            return URL(string: "https://api.openai.com/v1/responses")!
        case .custom:
            guard let custom = settings.custom else {
                throw AgentClientTransportError.streamError(
                    provider: .custom,
                    message: "No custom endpoint is configured."
                )
            }
            return custom.chatCompletionsURL
        }
    }
}
