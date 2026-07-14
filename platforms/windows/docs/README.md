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

`src/PalmierPro.DevHarness/` is a minimal WinUI3 window (`SwapChainPanel` named
`EngineSurface`) used to manually verify native engine milestones E1–E3 (decode,
composition, effect kernels) before the real Preview UI exists (Stage D).
