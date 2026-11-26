import Foundation
import Testing
@testable import CompositorPro

struct DiagnosticLogTests {
    @Test func credentialsAreStrippedFromAnythingWrittenToDisk() {
        // A support log gets pasted into issues, so nothing key-shaped may survive.
        #expect(!DiagnosticLog.redact("apiKey=sk-abc123def456ghi789").contains("abc123def456"))
        #expect(!DiagnosticLog.redact("Authorization: Bearer sk-or-v1-0123456789abcdef").contains("0123456789abcdef"))
        #expect(!DiagnosticLog.redact(#"{"api_key":"sk-ant-api03-AAAABBBBCCCC"}"#).contains("AAAABBBBCCCC"))
        #expect(!DiagnosticLog.redact("token: gsk_ABCDEFGHIJKLMNOP").contains("ABCDEFGHIJKLMNOP"))
        #expect(!DiagnosticLog.redact("secret=AIzaSyABCDEFGHIJKLMNOP").contains("SyABCDEFGHIJKLMNOP"))
    }

    @Test func redactionKeepsTheUsefulPartOfTheLine() {
        let line = DiagnosticLog.redact("chat turn a1b2 http status=401 host=api.example.com apiKey=sk-zzz999")
        #expect(line.contains("status=401"))
        #expect(line.contains("api.example.com"))
        #expect(line.contains("[redacted]"))
        #expect(!line.contains("zzz999"))
    }

    @Test func ordinaryDiagnosticsAreNotMangled() {
        #expect(DiagnosticLog.redact("tool inspect_media slow after=42000ms") == "tool inspect_media slow after=42000ms")
        #expect(DiagnosticLog.redact("model=stealth/space-bunny-alpha provider=custom") == "model=stealth/space-bunny-alpha provider=custom")
    }

    @Test func responseBodiesAreTruncatedBeforeTheyCanBecomeTheReport() {
        let long = String(repeating: "x", count: 5_000)
        let snippet = AgentDiagnostics.snippet(long)
        #expect(snippet.count < long.count)
        #expect(snippet.hasSuffix("…"))
        #expect(AgentDiagnostics.snippet("short\nbody") == "short body")
    }

    @Test func activityRingKeepsTheMostRecentEntries() {
        let ring = ActivityRing(capacity: 3)
        for index in 1...5 { ring.append("op-\(index)") }
        #expect(ring.snapshot() == ["op-3", "op-4", "op-5"])
    }

    @Test func toolSlowerThanTheThresholdIsFlagged() {
        // The failure this exists for: a tool that never returns leaves only its "in flight"
        // line, so the threshold is what turns silence into a report.
        #expect(AgentDiagnostics.slowOperationSeconds < 60)
        #expect(AgentDiagnostics.slowOperationSeconds > 5)
    }
}
