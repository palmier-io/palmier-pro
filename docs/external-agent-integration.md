# External Agent Integration

Status: Compositor Pro already hosts a working MCP server. External agents can
connect today. Session-scoped permissions and tool filtering are **not** built.

## How HyperFrames does it, and what that maps to here

HyperFrames integrates coding agents by running a local MCP server and pointing
the agent at it. Compositor Pro exposes the same shape: a local, loopback-only
MCP server that serves the full Compositor Pro tool surface to any MCP client.

There is no second protocol to implement, no adapter to write, and no CLI to
ship. Integration = configuring the agent to connect to the server that the
Mac app already runs.

## The running endpoint

- URL: `http://127.0.0.1:19789/mcp`
- Transport: MCP Streamable HTTP (also serves sessionless request/response on the same path)
- Auth: none; server binds to 127.0.0.1 only and is never reachable from the LAN
- Toggle: the MCP server is enabled by default and controlled by the app-level
  preference `io.compositor.pro.mcp.enabled` (see `MCPService.isEnabledPreference`).
  Disable it to turn the endpoint off.
- Tools: whatever the app registers in `MCPService.registerTools` — the full
  agent tool surface (timeline editing, media import, effects, export, and the rest).
- Images and project state: supplied through the same MCP resources/tools the
  built-in agent uses.

## Connecting the agents

All three speak MCP over HTTP. In each case, add the server to the agent's
MCP configuration and point it at the URL above. The exact config schema moves
between agent releases, so verify against the agent's current MCP docs.

**opencode** (`opencode.json` / `opencode.jsonc`): add an `mcp` entry of type
`remote` with the URL. Then start opencode with the Compositor Pro app running.

**Codex**: add an MCP server to `~/.codex/config.toml` under
`[mcp_servers.compositor_pro]` with `url = "http://127.0.0.1:19789/mcp"`.

**Claude Code**: `claude mcp add --transport http compositor-pro \
http://127.0.0.1:19789/mcp` (or the equivalent `.claude/mcp.json` entry).

Requirements the agent side will hit either way:

- The Compositor Pro app must be running (the server is hosted by the app, not a
  standalone binary).
- macOS only, and the request must come from localhost.
- The agent answers with tool calls; Compositor Pro executes them against the
  current project/timeline and returns the same structured receipts the in-app
  agent gets.

## Known gaps (deliberately not built)

These were considered and intentionally left out to keep the surface minimal:

- **Session registry / agent-specific permissions / tool allowlists.** No
  per-client policy exists today. Any local MCP client can call every tool the
  built-in agent can. If that is unacceptable for your threat model, leave the
  server disabled and use the in-app agent only.
- **Project context hub / change notifications.** External agents polling tool
  receipts is the supported mode; there is no streaming project-state feed.
- **Discovery endpoint** (`/.well-known/agent.json`), **SSE transport toggles**,
  **rate limiting**, **per-session API keys**, **audit logging**.
- **A stdio transport**. The server is HTTP-only today.

Before adding any of the above, write the user story (who connects, with what
project open, with what permissions, and how mistakes are recovered — e.g. undo).

## Verification plan

Manual, by design (external agents driving the editor is a UI-adjacent path):

1. Launch Compositor Pro with a project open.
2. Point opencode (or Codex / Claude Code) at the endpoint above.
3. Ask the agent to make one timeline edit (e.g. "split the current clip at 5
   seconds") and one export.
4. Confirm in the app: the edit lands on the timeline, undo works from the app's
   Undo menu, and the export file is produced.
5. Quit the app; confirm the agent's next call fails with a connection error.

Automated: the existing MCP tests already exercise tool handling over the
in-memory transport; there is no endpoint-level test for the HTTP listener
today.
