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
