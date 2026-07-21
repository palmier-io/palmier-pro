import Foundation

struct OllamaClient: AgentClient {
    let model: String
    let baseURL: URL

    init(model: String = "llama3.1", baseURL: URL = URL(string: "http://localhost:11434")!) {
        self.model = model
        self.baseURL = baseURL
    }

    func stream(
        system: String,
        tools: [AnthropicToolSchema],
        messages: [AnthropicMessage]
    ) -> AsyncThrowingStream<AnthropicStreamEvent, Error> {
        // Simplified Ollama implementation - adapt full streaming/tool calling as needed
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // TODO: Implement full Ollama /api/chat with tools
                    continuation.yield(.textDelta("[Ollama local model response placeholder - implement full streaming]"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
