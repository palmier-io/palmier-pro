# PalmierPro — Windows

Windows port of PalmierPro (WinUI 3 + C#/.NET). `Sources/PalmierPro` (the Mac app) is
untouched — this tree is fully self-contained under `platforms/windows/`. See
`../AGENTS.md` for conventions and `../../AGENTS.md` (root) for the one-line pointer.

## Prerequisites

- Windows 11
- Visual Studio 2022 (17.8+) with the **Desktop development with C++** workload
  (installs MSBuild + the v143 toolset — required for the native engine) and the
  **Windows App SDK** / WinUI component
- .NET 10 SDK (`global.json` pins `10.0.100`, `rollForward: latestFeature`)

## Build

The native engine (`PalmierEngine.dll`) and the managed solution are two separate
builds — see "Why the native project isn't in the .sln" below.

```powershell
# 1. Native engine (msbuild, not dotnet — vcxproj can't go through the dotnet CLI)
msbuild src\PalmierPro.Rendering\native\PalmierEngine.vcxproj -p:Configuration=Debug -p:Platform=x64

# 2. Managed solution
dotnet build PalmierPro.sln -c Debug -p:Platform=x64

# 3. Run
dotnet run --project src\PalmierPro.App\PalmierPro.App.csproj -c Debug
```

Or run all three in order: `.\scripts\dev.ps1`.

## Test

```powershell
dotnet test PalmierPro.sln -c Debug --filter "Category!=GPU"
```

`PalmierPro.App.Tests` is ViewModel/logic only — plain `dotnet test` has no WinUI
host, so WinUI types are never instantiated there. GPU-dependent tests carry
`[Trait("Category","GPU")]` and are excluded by default (CI runs a WARP-forced
subset instead).

## Release publish

`scripts/publish.ps1` builds a complete, self-contained payload under
`artifacts/publish/` — one command, no manual steps, and end users need
neither the .NET runtime nor Visual Studio/MSBuild installed to run it:

```powershell
.\scripts\publish.ps1
```

What it does:

1. Builds the native engine (`PalmierEngine.vcxproj`, Release|x64) via msbuild.
2. `dotnet publish`es `PalmierPro.App` as a self-contained `win-x64`
   deployment. `--self-contained true` is a separate switch from
   `WindowsAppSDKSelfContained=true` (already set in `PalmierPro.App.csproj`):
   the latter only bundles the Windows App SDK/WinUI runtime, not the .NET
   runtime itself — `--self-contained true` is what actually removes the
   "user must have .NET installed" requirement (bundles `hostfxr.dll`,
   `coreclr.dll`, `System.*.dll`, etc.).
3. Verifies the payload actually contains the native engine
   (`PalmierEngine.dll`), the FFmpeg DLLs, `shaders/`, bundled fonts
   (`Assets/Fonts/` for XAML, `fonts/` for the native text-compositing path),
   the CLR host, and the compiled XAML. That last one matters: plain
   `dotnet publish` silently drops the WinUI-generated `.xbf` files and the
   app's own resource index (`PalmierPro.App.pri`) — present in a normal
   `dotnet build` output, absent from `dotnet publish`'s — which crashes the
   published exe on its first `ms-appx:///` resource load. Fixed via the
   `IncludeWinUIXamlOutputInPublish` post-publish copy target in
   `PalmierPro.App.csproj` (and mirrored in `PalmierPro.DevHarness.csproj`
   for parity). The verification step fails loudly, naming whatever's
   missing, rather than shipping a payload that only half-runs.
4. Copies `THIRD_PARTY_NOTICES.md` and the repo `LICENSE` next to the exe.

`artifacts/publish/PalmierPro.App.exe` is the payload (~360 MB — self-contained
WinAppSDK + CLR + FFmpeg + bundled fonts). `PalmierPro.DevHarness` is **not**
included; its headless `--dump-frame`/`--dump-timeline-frame` paths are a
dev-only verification tool, not part of what ships.

### Version

`VERSION` (plain `MAJOR.MINOR.PATCH`, e.g. `0.1.0`) is the single source of
truth for the app's version: `Directory.Build.props` reads it into the
`Version` MSBuild property for every project under `platforms/windows`
(stamped into the published exe's file/product version), `publish.ps1` reads
the same file to log what it's building, and the installer (Stage E2, Inno
Setup) reads it too. Bump `VERSION`, not individual `csproj` files; a
`-p:Version=...` passed on the command line still overrides it if ever needed.

### ReadyToRun

Left off for now (`publish.ps1` does not pass `-p:PublishReadyToRun=true`).
R2R precompiles for faster cold start at the cost of a larger, RID-specific,
slower-to-build payload; revisit once startup latency is a measured problem,
not before.

## Installer

`scripts/build-installer.ps1` runs `publish.ps1` and then compiles
`installer/PalmierPro.iss` (Inno Setup 6) into
`artifacts/installer/PalmierProSetup-<version>.exe` — one command:

```powershell
.\scripts\build-installer.ps1
```

It resolves `ISCC.exe` itself: checks the usual Inno Setup 6 install
locations and `PATH`, and if none is found, installs Inno Setup 6 via
`winget install JRSoftware.InnoSetup --silent`, falling back to downloading
the official installer directly (`/VERYSILENT /CURRENTUSER`) if winget is
unavailable or fails. `AppVersion` is passed to ISCC via `/DAppVersion=...`,
read from `VERSION` — the same single-source version file `publish.ps1` and
`Directory.Build.props` use.

Install characteristics (`installer/PalmierPro.iss`):

- **Per-user, no admin required** (`PrivilegesRequired=lowest`). Installs to
  `%LOCALAPPDATA%\Programs\PalmierPro` — deliberately not
  `{autopf}` (Program Files), which per-user installs can't write to without
  elevation.
- **Start Menu shortcut** for the app and the uninstaller; no desktop icon.
- **GPLv3 license page** — shows the repo root `LICENSE` verbatim during
  interactive install.
- **Silent-install capable** out of the box (standard Inno Setup switches,
  no custom wizard pages to block on): `PalmierProSetup-<version>.exe
  /VERYSILENT /SUPPRESSMSGBOXES /NORESTART`.
- **Uninstall leaves user data alone.** The install directory
  (`%LOCALAPPDATA%\Programs\PalmierPro`) is unrelated to the app's state
  directory (`%LOCALAPPDATA%\PalmierPro` — project registry, `DiskCache`,
  Serilog logs; see `AppPaths.cs`). The uninstaller only removes what it put
  under the install directory, so projects/cache/logs survive an uninstall by
  construction — the `.iss` script has no `[UninstallDelete]` entries that
  touch `%LOCALAPPDATA%\PalmierPro`, and must not gain any.
- **Unsigned.** No Authenticode certificate exists yet, so Windows
  SmartScreen will warn on first run ("Windows protected your PC"). Signing
  and auto-update are deferred until a signed release channel exists (see the
  roadmap in `../AGENTS.md`).

## Why the native project isn't in the .sln

`PalmierPro.sln` contains only the C# projects. `src/PalmierPro.Rendering/native/PalmierEngine.vcxproj`
is deliberately **not** a solution member: the `dotnet` CLI cannot build `.vcxproj`
(fails with MSB4278 — vcxproj needs full MSBuild's C++ build tasks, which the
dotnet-hosted MSBuild doesn't carry). It's built by a separate `msbuild` invocation
instead, both in `scripts/dev.ps1` and in CI (`.github/workflows/ci.yml`). The
managed `PalmierPro.Rendering` project (P/Invoke layer, `NativeMethods.cs`) *is* in
the solution — only the native DLL project is excluded.

## XAML Hot Reload

XAML Hot Reload requires an active Visual Studio debug session (F5). `dotnet watch`
only gives C#-only hot reload — it does not reload XAML. For UI iteration, run from
Visual Studio.

## DevHarness

`src/PalmierPro.DevHarness/` is a minimal WinUI3 window used to manually verify
native engine milestones E1–E3 (decode, composition, effect kernels) before the
real Preview UI exists (Stage D). It has two tabs:

- **Media** (`SwapChainPanel` named `EngineSurface`, E1) — open a file, drag the
  time slider, and click **Show Frame** to decode + present that frame to the
  swap chain; resizing the window resizes the swap chain (quiesce ->
  `ResizeBuffers` -> re-`SetSwapChain`, per the threading contract documented in
  `native/include/palmier_engine.h`).
- **Timeline** (`TimelinePage.xaml`, E2) — **Open Project…** picks a `.palmier`
  package directory; **Build Demo Timeline…** picks two media files and builds a
  synthetic 2-track timeline in code (top track covers the left half of the
  canvas, so z-order is visible at a glance). Either path goes through
  `TimelineSnapshotBuilder` → `IVideoEngine` (`VideoEngine.OpenTimelineSessionAsync`/
  `UpdateTimelineAsync`), which is the actual Stage B "IVideoEngine v1" contract
  under test — not a shortcut around it. The scrub slider issues
  `PreviewSeekMode.InteractiveScrub` seeks while dragging and one `Exact` seek on
  release; the playhead readout and the seek→present latency readout both come
  from `IVideoEngine.PlayheadChanged`. **1x/2x** rebuilds the snapshot with the
  top clip's `Clip.Speed` doubled (`UpdateTimelineAsync`), exercising retiming
  live. A second, raw `PalmierPro.Rendering.TimelineSession` mirrors every seek
  purely so the `SwapChainPanel` has something to present — `IVideoEngine`'s
  swap-chain methods aren't timeline-scoped until Stage D's Preview UI lands (see
  `TimelinePage.xaml.cs`'s class remarks). Latency is logged via Serilog to
  `%LOCALAPPDATA%\PalmierPro\logs\devharness-*.log`.

Headless mode (no window, CI-facing):

```powershell
PalmierPro.DevHarness.exe --dump-frame <mediaPath> <seconds> <outPngPath>
PalmierPro.DevHarness.exe --dump-timeline-frame <projectOrSnapshotPath> <frame> <outPngPath>
```

`--dump-frame` decodes the frame at `<seconds>` and writes it straight to
`<outPngPath>` via `PE_RenderFrameToFile`. `--dump-timeline-frame` does the
timeline-ABI equivalent via `PE_TimelineRenderFrameToFile`: `<projectOrSnapshotPath>`
is either a `.palmier` package directory (built into a snapshot via
`TimelineSnapshotBuilder`, using `ActiveTimelineId` or the first timeline) or a
raw timeline-snapshot-v1 JSON file — pointing it straight at one of the checked-in
fixtures under `tests/*/Fixtures/` works too, since a literal `{{FIXTURE_DIR}}`
token in the JSON is substituted with the snapshot file's own directory. Neither
command touches a D3D device, swap chain, or display session, so both run on any
CI runner; exit code 0 on success. Implemented via a hand-written `Main`
(`DISABLE_XAML_GENERATED_MAIN`) so this path never calls `Application.Start`.

## Automation mode

`FileOpenPicker`/`FolderPicker` block on a human — a smoke test driving the real
UI would hang forever waiting for one. Set `PALMIER_AUTOMATION=1` and every
picker in `PalmierPro.App` and `PalmierPro.DevHarness` answers itself from
scripted env vars instead of showing a dialog (`AutomationMode`,
`src/PalmierPro.Services/AutomationMode.cs`):

| Variable | Answers |
|---|---|
| `PALMIER_AUTO_OPEN_PROJECT` | Open Project / open-existing-project pickers — `.palmier` package paths |
| `PALMIER_AUTO_SAVE_PATH` | New Project / Save As — full target path (split into directory + name) |
| `PALMIER_AUTO_IMPORT_FILES` | Media import / Build Demo Timeline — file paths for one invocation |
| `PALMIER_AUTO_PICK_FOLDER` | Any other folder picker |

Each variable is a queue: entries are `;`-separated and consumed one per picker
call, in order; `PALMIER_AUTO_IMPORT_FILES` groups are additionally
`,`-separated within one entry (one group = the file list for one import). An
exhausted or unset queue answers exactly what clicking Cancel would (`null`/empty)
— automation never falls through to a real dialog. Every answer is logged
(`automation: answered <kind> with <value>`).

```powershell
$env:PALMIER_AUTOMATION = "1"
$env:PALMIER_AUTO_OPEN_PROJECT = "C:\Projects\Demo.palmier"
$env:PALMIER_AUTO_IMPORT_FILES = "C:\Media\clip1.mp4,C:\Media\clip2.mp4"
PalmierPro.App.exe
```
