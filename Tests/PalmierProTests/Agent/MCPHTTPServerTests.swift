import Foundation
import Testing
@testable import PalmierPro

@Suite("MCP host binding and auth gating")
struct MCPHTTPServerTests {

    @Test func defaultsToLoopbackWhenHostIsBlank() {
        #expect(MCPHTTPServer.normalizedBindHost("127.0.0.1") == "127.0.0.1")
        #expect(MCPHTTPServer.normalizedBindHost("") == "127.0.0.1")
        #expect(MCPHTTPServer.normalizedBindHost("   ") == "127.0.0.1")
    }

    @Test func acceptsLocalhostAndValidIPv4() {
        #expect(MCPHTTPServer.normalizedBindHost("localhost") == "localhost")
        #expect(MCPHTTPServer.normalizedBindHost("0.0.0.0") == "0.0.0.0")
        #expect(MCPHTTPServer.normalizedBindHost("192.168.1.10") == "192.168.1.10")
    }

    @Test func trimsAndLowercasesHost() {
        #expect(MCPHTTPServer.normalizedBindHost("  192.168.1.10  ") == "192.168.1.10")
        #expect(MCPHTTPServer.normalizedBindHost("LOCALHOST") == "localhost")
    }

    @Test func rejectsMalformedHostsBackToLoopback() {
        #expect(MCPHTTPServer.normalizedBindHost("999.1.1.1") == "127.0.0.1")   // octet out of range
        #expect(MCPHTTPServer.normalizedBindHost("10.0.0") == "127.0.0.1")      // too few octets
        #expect(MCPHTTPServer.normalizedBindHost("10.0.0.1.5") == "127.0.0.1")  // too many octets
        #expect(MCPHTTPServer.normalizedBindHost("10.0.0.") == "127.0.0.1")     // empty trailing octet
        #expect(MCPHTTPServer.normalizedBindHost("example.com") == "127.0.0.1") // non-IPv4 hostname
    }

    @Test func loopbackHostsDoNotRequireBearerToken() {
        #expect(MCPHTTPServer.requiresBearerToken(bindHost: "127.0.0.1") == false)
        #expect(MCPHTTPServer.requiresBearerToken(bindHost: "localhost") == false)
        #expect(MCPHTTPServer.requiresBearerToken(bindHost: "") == false) // blank normalizes to loopback
    }

    @Test func nonLoopbackHostsRequireBearerToken() {
        #expect(MCPHTTPServer.requiresBearerToken(bindHost: "0.0.0.0") == true)
        #expect(MCPHTTPServer.requiresBearerToken(bindHost: "192.168.1.10") == true)
    }
}
