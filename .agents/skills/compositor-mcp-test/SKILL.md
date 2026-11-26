---
name: compositor-mcp-test
description: Verifies Compositor Pro Agent/MCP tool schemas, mutations, receipts, session behavior, and undo through isolated protocol tests. Use when changing ToolDefinitions, ToolExecutor, MCPService, MCPHTTPServer, or shared operations exposed by tools.
---

# Isolated Agent/MCP verification

All repository paths below resolve from the repository root, not this skill directory.

## Select the boundary

1. Read `docs/agents/rules/editor-and-tools.md` and `docs/agents/rules/verification.md`; load concurrency/package rules when reached by the tool.
2. Trace `Sources/CompositorPro/Agent/Tools/ToolDefinitions.swift`, the affected executor capability, the shared editor operation, and `Sources/CompositorPro/Agent/MCP/MCPService.swift`.
3. Start from the nearest existing protocol test. `Tests/CompositorProTests/Agent/ClipIdentityMCPTests.swift` covers identity/readback/undo; `Tests/CompositorProTests/Agent/SwapClipMediaToolTests.swift` demonstrates schema discovery. `Tests/CompositorProTests/Agent/ProjectPackageImportMCPTests.swift` covers persisted bytes and retained redo media.
4. Reuse `Fixtures` and the state ownership of `ToolHarness` from `Tests/CompositorProTests/Fixtures.swift` and `Tests/CompositorProTests/Agent/ToolExecutorTests.swift`. Do not copy legacy stub-file I/O: `ToolHarness.addAsset` touches disk on the main actor. Use off-main fixtures from `Tests/CompositorProTests/Project/ProjectPackageTestSupport.swift` for media. Direct executor calls are unit checks, not MCP-boundary proof.

## Exercise the protocol

5. Create an isolated editor/project/defaults and attach a retained `UndoManager` for mutations. Use unique disposable media/package fixtures and off-main I/O; never test against the user's project or app's normal MCP endpoint.
6. Register the real tools with `MCPService.registerTools`, connect an MCP `Client`/`Server` through `InMemoryTransport.createConnectedPair()`, and send requests with `client.callTool`. Match APIs to the installed Swift MCP SDK and nearby tests.
7. If definitions changed, call `client.listTools` and assert names, argument types/requirements/bounds, availability, and relevant descriptions. Verify stable IDs and machine-facing receipt values.
8. Exercise one representative user-intent request, invalid arguments/targets, and repeated/no-op behavior. Multi-entity failures must leave the entire state and undo history unchanged.
9. Independently read back timeline/library/project state through MCP or off-main persisted bytes. Check actual requested edits, links, media, metadata, and selection as relevant; never trust success receipts alone.
10. Exercise shared undo and compare exact pre-edit state. Use native history for redo unless discovery actually exposes a redo tool; do not invent protocol methods.
11. For jobs, inspect the terminal result and actual output; coordinate cancellation/stale completion with deterministic gates. Do not use polling or sleeps as a race test.
12. Stop/disconnect every started server/client and await fixture cleanup on success and failure. Run focused suites, then broader required gates.

## HTTP-specific changes

- In-memory tests cover MCP dispatch, not HTTP listener, session headers, binding, or transport lifecycle.
- Changes to `Sources/CompositorPro/Agent/MCP/MCPHTTPServer.swift` require an isolated listener on a non-conflicting port, disposable project, and real initialize/list/call/readback/teardown requests. Do not change the production port or use the user's running editor as setup.
- If the environment prevents HTTP or tool end-to-end checks, name the exact blocker and provide setup, requests, independent readback/undo, and expected failure/cancellation behavior as a manual plan. Do not label narrower tests end-to-end.
