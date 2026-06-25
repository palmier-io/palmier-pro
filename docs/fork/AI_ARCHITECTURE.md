# Fork: AI architecture, provider matrix & implementation specs

How the fork routes the LLM/agent and media generation off Palmier's hosted backend and
onto an OpenAI-compatible LiteLLM gateway + on-device Apple models. Status as of 2026-06-24.

## The two seams

- **Chat/agent** → the `AgentClient` protocol (`Agent/Clients/AgentClientTypes.swift:63`):
  `stream(system:tools:messages:) -> AsyncThrowingStream<AnthropicStreamEvent, Error>`.
  Provider selection is one choke point: `AgentService.selectClient()` (`AgentService.swift:52`).
  Adding a provider = a new conformer + a `selectClient` branch; the tool loop is untouched.
- **Media generation** → `GenerationBackend` (`Generation/GenerationBackend.swift`) is a concrete
  Convex enum with **no transport abstraction**. Routing it off Convex requires extracting a
  `GenerationTransport` protocol first.

## Provider matrix (chat/agent)

| Provider | Conformer | Where it shines | Status |
|---|---|---|---|
| Anthropic (cloud, BYO key) | `AnthropicClient` | existing default | shipped (upstream) |
| Palmier hosted | `PalmierClient` | the vendor path | cut in the fork (Convex) |
| **OpenAI-compatible / LiteLLM gateway** | `OpenAICompatClient` | local models, any provider; **primary driver** | **done, verified** (this branch) |
| **Apple Foundation Models** (on-device) | `AppleFoundationClient` (TODO) | free, private, offline, no key; **iPad default** | spec below |
| ACP external agent | `ACPClient` (TODO) | drive in-app chat with protoAgent/Claude/etc. | spec below |

`selectClient()` priority: gateway → Anthropic key → hosted account. Extend to: ACP session active →
on-device (if enabled) → gateway → Anthropic → hosted, as those land.

## Phased plan

0. **Unblock** — Xcode 26; `swift build && swift run` upstream; **compile + live-test Change 1** against the gateway.
1. **Provider layer (macOS = shared core)** — Change 2 (image gen), `AppleFoundationClient`, then Change 4 (video).
2. **Rebrand + cut cords** — same branch (see [REBRAND_AND_CORDS.md](REBRAND_AND_CORDS.md)); first GPLv3 macOS release.
3. **ACP** (optional).
4. **iPad port** — factor the platform-agnostic core from AppKit, build the iPadOS UI; on-device agent default.

---

## Change 1 — OpenAI-compatible chat client ✅ DONE (branch `feat/openai-compat-agent`)

`Agent/Clients/OpenAICompatClient.swift` + `OpenAICompatTypes.swift`:
- `GatewayConfig` (UserDefaults: base URL + model) + `GatewayKeychain` (optional key).
- `OpenAIRequestBody.build` — Anthropic message/tool shape → `/chat/completions` (system, `tool_use`→`tool_calls`,
  `tool_result`→`role:tool`, image→`image_url`); **drops `cache_control`** (separate builder, not a wrapper).
- `OpenAISSEDecoder` (sync, testable) + `OpenAISSE.parse` (async) — content deltas + **index-keyed `tool_calls`
  accumulation** flushed on `finish_reason`; `tool_calls`→`.toolUse`, `length`→`.maxTokens`, else `.endTurn`.
- `AgentService`: gateway state + observer, `hasGateway`, `canStream`, `selectClient` (gateway first).
- `AgentPane`: "Custom Gateway (OpenAI-compatible)" fields; `AgentPanelView`: "using \<model\>" indicator.

**Verified** via `Tests/PalmierProTests/Agent/OpenAICompatTests.swift` (swift-testing, 13 cases) — run with a
standalone swiftc 6.1.2 harness (13/13). **Pending on Xcode 26:** full compile + a real-gateway SSE smoke test.
The gateway model `name` is a **LiteLLM alias** (per protoAgent's pattern) — swap models by editing the gateway, not the app.

---

## Change 2 — image generation → gateway (TODO, ~1 wk, low risk)

OpenAI images API is standardized; LiteLLM proxies `POST /v1/images/generations` to 9 providers. The work is
PalmierPro-side coupling, not the API.

1. **Extract `GenerationTransport`** from `GenerationBackend.swift`: `submit()`, `subscribe()`, `uploadReference()`.
   Wrap today's Convex code as `ConvexGenerationTransport`.
2. **`OpenAICompatGenerationTransport` + `ImageGenerationClient`** (new): POST `/v1/images/generations`
   (`model`, `prompt`, `size`, `quality`, `n`); **gpt-image-1 returns `b64_json` only** — handle both `response_format`s.
   Synchronous (URLs/b64 in the response) — skip the Convex Combine job loop in `GenerationService.runJob()`
   and the 3-step `uploadReference` (OpenAI takes base64 inline).
3. **Static catalog** — `ModelCatalog` (`Generation/Catalog/ModelCatalog.swift:47`) hard-fails without Convex
   `models:list`; ship a bundled JSON. Shape per entry: `{ id, displayName, kind: image|video|audio, sizes[],
   supportsReferences, costHint }`. `id` = your gateway alias.
2. **Gate bypass** — `isSignedIn`+`hasCredits` guards at `ToolExecutor+Generate.swift:6-10,198-202,319-323` +
   `EditSubmitter.swift`. Replace all with one `AccountService.generationGateEnabled` (false when a non-Convex
   transport is configured).
3. **`LiteLLMGateway.swift`** (new) — shared `baseURL + apiKey` for the image + video clients (reuse `GatewayConfig`).

---

## Change 4 — video generation → gateway (TODO, scope carefully)

LiteLLM DOES expose an OpenAI-compatible `POST /v1/videos` (OpenAI/Azure/Gemini-Veo/Vertex-Veo/RunwayML/ModelsLab
— docs.litellm.ai/docs/videos). It is an **async job**: create → poll `GET /v1/videos/{id}` (queued/in_progress/
completed/failed) → download. `VideoGenerationClient.swift` (new): model-string-agnostic, poll or webhook.
**ComfyUI is not a native LiteLLM provider** → add a LiteLLM pass-through endpoint for it (separate work item).
Needs a progress UI contract (the async poll loop) — a UX decision that gates the client.

---

## AppleFoundationClient — on-device provider (TODO, the iPad default)

Apple **Foundation Models** (macOS/iPadOS 26, Apple-Intelligence-gated; M-series): `LanguageModelSession` with
streaming (snapshots), guided generation, and **native tool calling** via the `Tool` protocol. **Core AI** (the
URL you shared) is the runtime beneath it (Core ML lineage; already how SigLIP2 search runs).

Design: `AppleFoundationClient: AgentClient`.
- Gate on `SystemLanguageModel.availability`; surface a clear "on-device model unavailable" when not.
- Map the editor's tools → Foundation Models `Tool` conformers (one per edit op) — the in-process analogue of the
  MCP tool surface. **Note:** Foundation Models runs the tool loop *internally* (the session calls your `Tool`s and
  continues), unlike the Anthropic loop where the client surfaces `tool_use` and the app executes. So this conformer
  is more than a thin transport — it either (a) runs its own loop and emits synthesized `AnthropicStreamEvent`s to
  fit `runLoop`, or (b) bypasses `runLoop` for an on-device path. Decide before implementing.
- Tradeoff: smaller than a frontier model — great for everyday edits + privacy/offline; gateway is the heavy-lift fallback.

---

## ACP — drive the in-app chat with an external agent (TODO, optional)

The editor becomes an ACP **client** that spawns an agent subprocess over stdio JSON-RPC (the inverse of the
inbound MCP server). Reference: protoAgent `plugins/coding_agent/acp_client.py` (proto is the ACP client) +
`runtime/acp_agents.py` (agent catalog: `proto --acp`, `claude-agent-acp`, `codex-acp`, `gemini --experimental-acp`).

- `Agent/ACP/ACPClient.swift` — actor over `Foundation.Process`; JSON-RPC 2.0 over stdin/stdout:
  `initialize` → `session/new`|`session/load` → `session/prompt` → stream `session/update`
  (`agent_message_chunk`→text) → `session/cancel`/`session/close`; handle inbound `session/request_permission`.
- `runACPLoop()` replaces `AgentService.runLoop()`; the panel UI is unchanged.
- Composability: pass `mcpServers:[{url:"http://127.0.0.1:19789/mcp"}]` in `session/new` so the agent drives the
  editor back through our own MCP server.
- **No official Swift ACP SDK.** Community: `rebornix/acp-swift-sdk`, `wiedymi/swift-acp` — vendor in-repo + own it,
  or hand-roll (~250-300 lines). Hazards: `Process.terminate()` leaves grandchild `node` alive → `killpg(SIGKILL)`
  (ok in a non-sandboxed app); need a custom ~32 MB line buffer (FileHandle async-bytes has no line cap);
  `request_permission` is an inbound request (has `id`) so the continuation map is bidirectional.

---

## iPad (M4) — port + on-device agent

Real iPadOS port, not a recompile. **Portable:** AVFoundation export/preview, the timeline model + math, Speech
transcription, CoreML SigLIP2 search, the AgentClient network clients, all Codable models. **Rework (major):** the
non-sandboxed file/document model (`Models/MediaResolver.swift:21` raw absolute paths, no bookmarks → `UIDocument` +
security-scoped bookmarks); the AppKit shell (`NSApplication`/`NSDocumentController`/`NSMenu`); the ~4k-LOC custom-
NSView **touch timeline** (`Timeline/TimelineView.swift`, `TimelineInputController.swift` → gestures); the 5-pane
`NSSplitViewController` editor (`Editor/EditorView.swift`). **Drop:** Sparkle, the loopback MCP server, Developer-ID.

Agent on iPad lives **in-app**: `AppleFoundationClient` is the default (free/private/offline); the gateway is the
power option (same code). Generation routes to the gateway (same code both platforms). The "fleet drives the editor
over loopback MCP" model does NOT transfer to iPad.

**Distribution (GPL-clean):** sideload your own build to your own iPad — Xcode personal team (free, 7-day re-sign)
or the $99 Developer Program (1-yr provisioning). Running your own build is private use, **not** distribution → no
GPL conflict. The App Store is the only place GPLv3 can't go.

## Risks (consolidated, biggest first)
1. **Video standard gap** — `/v1/videos` is OpenAI-proprietary + uneven provider parity; ComfyUI is a separate
   passthrough adapter. → async-job + model-string-agnostic.
2. **gpt-image-1 is b64_json-only** — handle both `response_format`s.
3. **Convex gate bypass is multi-site** → collapse to one `generationGateEnabled` flag.
4. **Tool-call SSE accumulation (Change 1)** → covered by tests; still smoke-test on a real gateway.
5. **No official Swift ACP SDK** → vendor + own.
6. **On-device model capability** vs a frontier model for complex multi-tool editing → default on-device, escalate to gateway.
7. **iPad port surface** (AppKit UI + sandbox/file model) is the real cost — everything else ports.
