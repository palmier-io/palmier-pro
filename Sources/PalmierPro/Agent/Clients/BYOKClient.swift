import Foundation

struct BYOKClient: AgentClient {
    let apiKey: String
    let baseURLString: String?
    let settings: AgentRunSettings

    init(apiKey: String, baseURLString: String? = nil, settings: AgentRunSettings) {
        self.apiKey = apiKey
        self.baseURLString = baseURLString
        self.settings = settings
    }

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
        guard !apiKey.isEmpty else { throw AgentClientTransportError.missingAPIKey(provider) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        switch provider {
        case .anthropic:
            request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAI:
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

    private var endpoint: URL {
        settings.model.provider.chatEndpoint(baseURLString: baseURLString)
    }
}
