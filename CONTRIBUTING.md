# Contributing

## How to contribute

The best way to contribute is to open a Github issue. Bug reports, feature requests, ideas are welcome.

With AI coding, human reviews are the bottleneck. We don't have the bandwidth to review large unsolicited PRs.

## Getting Started

### Prerequisites
- macOS 26+
- Xcode 16+
- Swift 6.2 toolchain

### Develop
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

### Windows (in development)

The Windows port lives under `platforms/windows/` — see `platforms/windows/docs/README.md`
and `platforms/windows/AGENTS.md` for details.

**Prerequisites:**
- Visual Studio 2022 with the **Desktop development with C++** workload (native
  engine build) and the Windows App SDK / WinUI component
- .NET 10 SDK

**Develop:**
```powershell
cd platforms/windows

# Native engine (msbuild — the dotnet CLI can't build vcxproj)
msbuild src\PalmierPro.Rendering\native\PalmierEngine.vcxproj -p:Configuration=Debug -p:Platform=x64

# Managed solution
dotnet build PalmierPro.sln -c Debug -p:Platform=x64

# Run
dotnet run --project src\PalmierPro.App\PalmierPro.App.csproj -c Debug
```

Or `.\scripts\dev.ps1` to run all three in order.

## Test

```bash
swift test
```

By contributing, you agree your contributions are licensed under [GPLv3](LICENSE).
