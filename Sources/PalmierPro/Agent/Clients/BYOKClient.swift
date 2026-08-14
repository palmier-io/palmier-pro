import Foundation

struct BYOKClient: AgentClient {
    let apiKey: String
    let settings: AgentRunSettings
    var customProvider: CustomAgentProvider?

    init(apiKey: String, settings: AgentRunSettings, customProvider: CustomAgentProvider? = nil) {
        self.apiKey = apiKey
        self.settings = settings
        self.customProvider = customProvider ?? settings.customProvider
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
        guard !apiKey.isEmpty else {
            if let custom = customProvider {
                throw AgentClientTransportError.missingCustomAPIKey(custom.name)
            }
            throw AgentClientTransportError.missingAPIKey(settings.model.provider)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        if let _ = customProvider {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            switch settings.model.provider {
            case .anthropic:
                request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            case .openAI:
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
        }
        request.httpBody = try JSONSerialization.data(
            withJSONObject: settings.requestBody(system: system, tools: tools, messages: messages),
            options: [.sortedKeys]
        )

        let bytes = try await AgentHTTP.bytes(for: request) { status, body in
            if let custom = customProvider {
                return AgentClientTransportError.customHTTPError(providerName: custom.name, status: status, body: body)
            }
            return AgentClientTransportError.httpError(provider: settings.model.provider, status: status, body: body)
        }
        if customProvider != nil {
            try await CustomSSE.parse(bytes: bytes, continuation: continuation)
        } else {
            try await settings.model.provider.parseSSE(bytes: bytes, continuation: continuation)
        }
    }

    private var endpoint: URL {
        if let custom = customProvider {
            return custom.baseURL
        }
        switch settings.model.provider {
        case .anthropic:
            URL(string: "https://api.anthropic.com/v1/messages")!
        case .openAI:
            URL(string: "https://api.openai.com/v1/responses")!
        }
    }
}
