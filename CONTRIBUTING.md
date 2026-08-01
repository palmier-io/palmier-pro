# Contributing

## How to contribute

Inspired by https://github.com/yc-software/qm/blob/main/CONTRIBUTING.md,
We take contributions as human-written text, not code. Submit a Github issues on feature requests, ideas, bug reports,
and we will handle the implementation.

## Self Host Getting Started

### macOS

**Prerequisites:** macOS 26+, Xcode 16+, Swift 6.2 toolchain.

```bash
git clone https://github.com/palmier-io/palmier-pro
cd palmier-pro

swift build
swift run
```

For a bundled debug build that launches the `.app` and streams OSLog:

```bash
./scripts/dev.sh
```

```bash
swift test
```

### Windows

**Prerequisites:** Windows 10 1809+ (x64), [.NET 8 SDK](https://dotnet.microsoft.com/download/dotnet/8.0).

Full guide: [windows/README.md](windows/README.md) (architecture, MCP, models, Velopack installer).

```powershell
git clone https://github.com/palmier-io/palmier-pro
cd palmier-pro

# Use "powershell" (Windows PowerShell 5.1) or "pwsh" (PowerShell 7+)
powershell -ExecutionPolicy Bypass -File windows/scripts/fetch-models.ps1   # optional
dotnet run --project windows/src/PalmierPro.App/PalmierPro.App.csproj -c Debug -p:Platform=x64
```

**Installer (Velopack):**

```powershell
# If "No .NET SDKs were found", fix PATH first (user-local SDK):
$env:DOTNET_ROOT = "$env:LOCALAPPDATA\Microsoft\dotnet"
$env:PATH = "$env:DOTNET_ROOT;$env:USERPROFILE\.dotnet\tools;$env:PATH"

powershell -ExecutionPolicy Bypass -File windows/scripts/pack.ps1 -Version 0.1.0
# Run: windows/artifacts/velopack/PalmierPro-win-Setup.exe
```

```powershell
dotnet test windows/tests/PalmierPro.Agent.Tests
dotnet test windows/tests/PalmierPro.Core.Tests
```

By contributing, you agree your contributions are licensed under [GPLv3](LICENSE).
