# External Agent Integration

Compositor Pro can run installed agents directly in its chat, or expose its MCP
server to an agent running in another app. The external server has no per-client
permission policy.

## How HyperFrames does it, and what that maps to here

HyperFrames Studio launches installed coding-agent CLIs inside its chat and uses
their signed-in accounts. Compositor Pro supports this workflow for Codex,
Claude Code, and Antigravity, and also supports external MCP clients.

## Use an agent in Compositor chat

Open **Connect agent**, select **Use in chat**, and choose an installed agent.
Sign in once using the displayed Terminal command if needed. Leave **Model ID**
empty for the CLI's configured model, or enter a supported model ID. Choose
**Use in chat**, then send requests in Compositor's own chat panel. The chat
selector also lists installed agents above API models.

Each run supplies a temporary workspace and a loopback MCP connection bound to
that chat's editor. No external MCP configuration is needed. The tool catalog
uses the in-app editing operations and omits `manage_project`, so a run cannot
retarget another project. Tool work, process shutdown, and workspace cleanup are
awaited when a run stops. At most two local agent processes run concurrently.
The inactivity watchdog stops a process after 15 minutes without stream output;
active tool and response updates extend the deadline. A timeout preserves edits
already applied and does not automatically replay the request.

The app uses the official headless interfaces: `codex exec --json`,
`claude --print --output-format stream-json`, and
`agy --input-format stream-json --output-format stream-json`. Replies stream
into the originating Compositor chat; tools already executed by the CLI are
never submitted a second time by the native chat loop. Runs use the CLI account
and its billing, without requiring a separate API key in Compositor.

Antigravity's app manages external servers under **Customizations → Installed →
MCP Servers**. The Antigravity IDE uses its agent panel's MCP Servers menu.

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

For native chat, use a disposable project and verify:

1. Select each installed agent in **Connect agent → Use in chat**, leave the
   model ID empty, and confirm the chat selector shows the chosen agent.
2. Request a timeline summary, then one clip move. Confirm the response stays
   in its chat, the timeline changes once, and native Undo restores it.
3. Switch chats while a request runs, then stop the original request. Confirm
   the other chat is unchanged and the agent exits before Stop completes.
4. Dismiss the connection sheet with Escape; check a missing CLI is disabled
   and an unsupported model or missing CLI sign-in produces an actionable error.
   Close the disposable project during a run and confirm no late edit appears.

Automated coverage includes isolated HTTP discovery, clip movement, independent
timeline readback, shared undo, and stale-run refusal in `LocalAgentChatMCPTests`.
`LocalAgentProcessTests` verifies pipe draining and cancellation, including an
agent that ignores normal termination. The existing MCP tests also exercise
tool dispatch through the in-memory transport and HTTP listener lifecycle.
