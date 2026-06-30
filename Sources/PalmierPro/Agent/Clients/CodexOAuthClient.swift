import Foundation

struct CodexOAuthClient: AgentClient {
    let model: String
    var maxTokens: Int = 8192

    func stream(
        system: String,
        tools: [AgentToolSchema],
        messages: [AgentClientMessage]
    ) -> AsyncThrowingStream<AgentStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let accessToken = try await CodexOAuthStore.accessToken(refreshIfNeeded: true)
                    guard let endpoint = OpenAICompatibleEndpoint.normalizedURL(from: CodexOAuthAgentSettings.baseURL) else {
                        throw CodexOAuthError.invalidHTTPResponse
                    }
                    let client = OpenAICompatibleClient(
                        settings: OpenAICompatibleSettings(
                            baseURL: CodexOAuthAgentSettings.baseURL,
                            endpoint: endpoint,
                            model: model,
                            apiKey: accessToken
                        ),
                        maxTokens: maxTokens
                    )
                    for try await event in client.stream(system: system, tools: tools, messages: messages) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
