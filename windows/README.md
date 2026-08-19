# Palmier Pro — Windows

WinUI 3 / .NET 8 port of Palmier Pro. Same filmmaker + Agent tool contracts as macOS; Apple-only tech is substituted (Whisper, Media Foundation, Velopack).

Mac remains the primary product surface. This tree is the Windows implementation under `windows/`.

## Requirements

| Item | Notes |
|------|--------|
| Windows 10 1809+ (build 17763) or Windows 11 | x64 (ARM64 project configs exist; x64 is the default) |
| [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0) | Includes the runtime for `dotnet run` |
| Windows App SDK | Pulled by the App project (`Microsoft.WindowsAppSDK` 1.7.*) |
| Optional: [vpk](https://docs.velopack.io/) | `dotnet tool install -g vpk` — needed to build the installer |

No Visual Studio is required for CLI builds. VS 2022 with the WinUI workload is fine if you prefer the IDE (`windows/PalmierPro.sln`).

## Quick start — run from source

From the repo root:

```powershell
# Optional but recommended: local Whisper + Silero models
# Use "powershell" on Windows PowerShell 5.1; "pwsh" if PowerShell 7+ is installed.
powershell -ExecutionPolicy Bypass -File windows/scripts/fetch-models.ps1

# Build + run the editor (self-contained WinUI)
dotnet build windows/src/PalmierPro.App/PalmierPro.App.csproj -c Debug -p:Platform=x64
dotnet run --project windows/src/PalmierPro.App/PalmierPro.App.csproj -c Debug -p:Platform=x64
```

Or open `windows/PalmierPro.sln` in Visual Studio and F5 the `PalmierPro.App` project (x64).

The executable lands under:

`windows/src/PalmierPro.App/bin/x64/Debug/net8.0-windows10.0.19041.0/win-x64/PalmierPro.exe`

First launch opens the home window (recent projects / new project). Opening a project opens the five-pane editor.

### Tests

```powershell
dotnet test windows/tests/PalmierPro.Agent.Tests
dotnet test windows/tests/PalmierPro.Core.Tests
dotnet test windows/tests/PalmierPro.Media.Tests   # if present
dotnet test windows/tests/PalmierPro.Cloud.Tests   # if present
```

## Installer — pack and try a real install

Windows shipping uses [Velopack](https://docs.velopack.io/) (macOS Sparkle counterpart). `windows/scripts/pack.ps1` publishes a self-contained build, then packs an installer.

```powershell
# One-time
dotnet tool install -g vpk

# From repo root — publishes + packs
powershell -ExecutionPolicy Bypass -File windows/scripts/pack.ps1 -Version 0.1.0

# Optional flags: -Runtime win-x64 -Configuration Release
```

### Outputs

| Path | What it is |
|------|------------|
| `windows/artifacts/publish/win-x64/` | Raw published app (`PalmierPro.exe` + deps) |
| `windows/artifacts/velopack/PalmierPro-win-Setup.exe` | **Installer** — run this to install |
| `windows/artifacts/velopack/PalmierPro-win-Portable.zip` | Portable zip (no install) |
| `windows/artifacts/velopack/*-full.nupkg` | Update package |
| `windows/artifacts/velopack/releases.*.json` / `RELEASES` | Update feed manifests |

### Try it locally

1. Run `PalmierPro-win-Setup.exe` from `windows/artifacts/velopack/`.
2. Velopack installs under the user local apps folder and launches the app (Start Menu / Desktop shortcuts).
3. Auto-update checks the feed at  
   `https://github.com/palmier-io/palmier-pro/releases/latest/download`  
   or `PALMIER_UPDATE_URL` / Settings → update feed.

If packaging is skipped, you can still run  
`windows/artifacts/publish/win-x64/PalmierPro.exe` directly (no Velopack updates).

### “No .NET SDKs were found”

Your machine may have a host-only `C:\Program Files\dotnet` ahead of a user-local SDK. Before packing, either reopen the terminal after installing the SDK, or:

```powershell
$env:DOTNET_ROOT = "$env:LOCALAPPDATA\Microsoft\dotnet"
$env:PATH = "$env:DOTNET_ROOT;$env:USERPROFILE\.dotnet\tools;$env:PATH"
dotnet --list-sdks   # should print 8.0.x
```

`pack.ps1` now applies this automatically when the local SDK exists.

### Point updates at your own folder (dev)

```powershell
# Serve the velopack folder over HTTP, then:
$env:PALMIER_UPDATE_URL = "http://127.0.0.1:8000/"
# Launch the Velopack-installed app (not the raw Debug exe)
```

Debug/`dotnet run` builds are **not** Velopack-installed; Settings will say updates require a Velopack install.

---

## Architecture — how the pieces work

```
┌─────────────────────────────────────────────────────────────┐
│  PalmierPro.App     WinUI shell: Home, Editor, Settings     │
│  Agent chat · MCP host · Velopack · preview SwapChain       │
└─────────────┬───────────────────────┬───────────────────────┘
              │                       │
┌─────────────▼──────────┐  ┌─────────▼──────────────────────┐
│  PalmierPro.Agent      │  │  PalmierPro.Media              │
│  ToolExecutor · MCP    │  │  MF decode · D2D composite     │
│  TimelineReceipt       │  │  Whisper · ONNX · export       │
└─────────────┬──────────┘  └─────────┬──────────────────────┘
              │                       │
┌─────────────▼───────────────────────▼──────────────────────┐
│  PalmierPro.Core                                             │
│  Timeline model · EditOperations · undo · .palmier package   │
│  ProjectPackageCoordinator · SourceTiming (BWF/rtmd)         │
└─────────────────────────────────────────────────────────────┘
              │
┌─────────────▼──────────┐
│  PalmierPro.Cloud      │  Account · generation API client
└────────────────────────┘
```

### Projects

| Project | Role |
|---------|------|
| **Core** | Domain model (`Timeline`, `Clip`, `Track`), `TimelineEditOperations*`, undo, serialization, `.palmier` package I/O, search index types. No WinUI. |
| **Media** | Media Foundation playback/export, D2D frame compositor, Whisper/ONNX, filmstrips, waveforms. |
| **Agent** | 47 Mac-parity tools, `ToolExecutor`, mutation/timeline receipts, loopback MCP HTTP server. |
| **Cloud** | Convex/account + generation job client. |
| **App** | WinUI windows, theme, agent host adapter (`AgentEditorHost`), Velopack bootstrap. |

### Editor UI (Default layout)

```
┌──────────┬──────────────────────────────┐
│  Agent   │  Media  │  Preview  │ Inspect │
│ (full H) ├──────────────────────────────┤
│          │         Timeline              │
└──────────┴──────────────────────────────┘
```

- **Agent** — in-app chat; same tools as MCP.
- **Media** — import / folder / generate / search; AI badges on generated tiles.
- **Preview** — D3D/SwapChain preview, transport, format chips.
- **Inspector** — clip properties or project Settings (resolution / fps / aspect).
- **Timeline** — Win2D canvas; pointer (V) / razor (C); Mac clip colors.

### Projects on disk

- Projects are `.palmier` packages (directory / zip-compatible layout): timeline JSON + `media/` assets.
- Live media installs go through `PackageMediaInstaller` + `ProjectPackageCoordinator` (stage → prepare → atomic install). Do not write into a live package from feature code ad hoc.

### Agent + MCP

- Tool names match Mac (`get_timeline`, `add_clips`, `organize_media`, …).
- When a project is open and MCP is enabled in Settings, App starts `McpHttpServer` on **`http://127.0.0.1:19789/mcp`** (same port as Mac).
- Connect Cursor / Claude Code the same way as the root README MCP section.
- Generation tools create library placeholders, download results into the package when URLs land, and can place AI gap-fill clips via `startFrame`/`endFrame`.

### Playback & export

- Preview: Media Foundation decode → D2D compositing → SwapChain panel.
- Export: H.264 / H.265 / FCPXML / XML / `.palmier`. **ProRes is refused.** Mezzanine = high-bitrate HEVC.
- Sync: audio cross-correlation; timecode via BWF + Sony `rtmd` (not QuickTime `tmcd`).

### On-device ML

| Model | Use |
|-------|-----|
| Whisper (`ggml-*.bin`) | Local STT / captions |
| Silero VAD | `remove_silence` |
| Optional SigLIP ONNX | Visual `search_media` (else frame-feature embed) |
| DeepFilter ONNX | Probed only; **spectral gate** is the active denoise path |

See [models/README.md](models/README.md). App also auto-fetches Whisper/Silero into `%LocalAppData%\PalmierPro\models\` on first use if missing.

### Settings & data locations

| Data | Location |
|------|----------|
| App settings | `%LocalAppData%\PalmierPro\` (via `SettingsStore`) |
| Downloaded models | `%LocalAppData%\PalmierPro\models\` |
| Denoise cache | `%LocalAppData%\PalmierPro\denoise\` |
| Agent feedback JSON | `%LocalAppData%\PalmierPro\feedback\` |

Useful env vars:

| Variable | Purpose |
|----------|---------|
| `PALMIER_WHISPER_MODEL` | Absolute path to Whisper ggml |
| `PALMIER_SILERO_MODEL` | Absolute path to Silero ONNX |
| `PALMIER_SIGLIP_MODEL` / `PALMIER_DEEPFILTER_MODEL` | Optional ONNX overrides |
| `PALMIER_UPDATE_URL` | Velopack update feed base URL |
| `ANTHROPIC_API_KEY` | In-app Agent (when using Anthropic) |

---

## Platform parity

See [docs/FEATURE_PARITY_CHECKLIST.md](docs/FEATURE_PARITY_CHECKLIST.md) for status, intentional substitutes, and contract deltas vs Mac.

## Troubleshooting

| Symptom | What to try |
|---------|-------------|
| Build fails on PRI / Windows App SDK | Ensure `-p:Platform=x64` and .NET 8 SDK; App sets `EnableMsixTooling=true` for CLI |
| Blank window / crash on start | Confirm Windows 10 1809+; try Release publish once |
| No speech / captions | `fetch-models.ps1` or wait for LocalAppData auto-download |
| “Updates require a Velopack-installed build” | Expected for `dotnet run`; use `PalmierPro-Setup.exe` |
| MCP connection refused | Open a project; enable MCP in Settings; port **19789** |
| ProRes export error | Expected — use H.265 / mezzanine HEVC |
