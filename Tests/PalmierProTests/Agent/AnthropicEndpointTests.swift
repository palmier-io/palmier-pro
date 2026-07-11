import Foundation
import Testing
@testable import PalmierPro

@Suite("Anthropic endpoint resolution")
struct AnthropicEndpointTests {

    // MARK: - messagesURL(base:)

    @Test func defaultBaseAppendsMessagesPath() {
        let url = AnthropicEndpoint.messagesURL(base: AnthropicEndpoint.defaultBaseURL)
        #expect(url.absoluteString == "https://api.anthropic.com/v1/messages")
    }

    @Test func blankBaseFallsBackToDefault() {
        #expect(AnthropicEndpoint.messagesURL(base: "").absoluteString
            == "https://api.anthropic.com/v1/messages")
        #expect(AnthropicEndpoint.messagesURL(base: "   ").absoluteString
            == "https://api.anthropic.com/v1/messages")
    }

    @Test func customProxyHostIsHonored() {
        // The VibeProxy example from the issue.
        let url = AnthropicEndpoint.messagesURL(base: "http://127.0.0.1:8318")
        #expect(url.absoluteString == "http://127.0.0.1:8318/v1/messages")
    }

    @Test func trailingSlashesAreStripped() {
        #expect(AnthropicEndpoint.messagesURL(base: "http://127.0.0.1:8318/").absoluteString
            == "http://127.0.0.1:8318/v1/messages")
        #expect(AnthropicEndpoint.messagesURL(base: "http://127.0.0.1:8318///").absoluteString
            == "http://127.0.0.1:8318/v1/messages")
    }

    @Test func surroundingWhitespaceIsTrimmed() {
        let url = AnthropicEndpoint.messagesURL(base: "  https://proxy.example.com  ")
        #expect(url.absoluteString == "https://proxy.example.com/v1/messages")
    }

    @Test func proxyPathPrefixIsPreserved() {
        // Gateways that mount the API under a sub-path keep it.
        let url = AnthropicEndpoint.messagesURL(base: "https://gw.example.com/anthropic")
        #expect(url.absoluteString == "https://gw.example.com/anthropic/v1/messages")
    }

    // MARK: - persistence round-trip

    @Test func saveAndClearRoundTrip() {
        let previous = AnthropicEndpoint.storedBaseURL()
        defer { AnthropicEndpoint.save(previous ?? "") }

        AnthropicEndpoint.save("  http://127.0.0.1:8318  ")
        #expect(AnthropicEndpoint.storedBaseURL() == "http://127.0.0.1:8318")

        // Saving a blank value clears the override and restores the default.
        AnthropicEndpoint.save("")
        #expect(AnthropicEndpoint.storedBaseURL() == nil)
    }
}
