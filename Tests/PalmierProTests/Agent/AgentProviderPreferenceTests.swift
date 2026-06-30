import Foundation
import Testing
@testable import PalmierPro

@Suite("Agent provider preference")
struct AgentProviderPreferenceTests {

    @Test func defaultProviderPrefersConfiguredExternalBackendsBeforeAnthropic() {
        let existing = UserDefaults.standard.string(forKey: AgentProviderPreference.defaultsKey)
        defer {
            if let existing {
                UserDefaults.standard.set(existing, forKey: AgentProviderPreference.defaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: AgentProviderPreference.defaultsKey)
            }
        }
        UserDefaults.standard.removeObject(forKey: AgentProviderPreference.defaultsKey)
        #expect(AgentProviderPreference.defaultProvider(
            hasAnthropicKey: true,
            hasOpenAICompatibleConfig: false,
            hasCodexOAuthConfig: false,
            hasZhipuCodingPlanConfig: true
        ) == .zhipuCodingPlan)

        #expect(AgentProviderPreference.defaultProvider(
            hasAnthropicKey: true,
            hasOpenAICompatibleConfig: false,
            hasCodexOAuthConfig: true,
            hasZhipuCodingPlanConfig: false
        ) == .anthropic)

        #expect(AgentProviderPreference.defaultProvider(
            hasAnthropicKey: false,
            hasOpenAICompatibleConfig: false,
            hasCodexOAuthConfig: true,
            hasZhipuCodingPlanConfig: false
        ) == .codexOAuth)
    }
}
