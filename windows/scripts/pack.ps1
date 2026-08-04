<#
.SYNOPSIS
  Publish and pack Palmier Pro for Velopack auto-update.

.DESCRIPTION
  1. dotnet publish → windows/artifacts/publish/<runtime>/
  2. vpk pack → windows/artifacts/velopack/ (Setup.exe + nupkg + releases)

  Update feed: PALMIER_UPDATE_URL or
    https://github.com/palmier-io/palmier-pro/releases/latest/download

  Requires: .NET 8 SDK, and (for packaging) `dotnet tool install -g vpk`.

.PARAMETER Version
  Semantic version stamped on the build (default 0.1.0).

.PARAMETER Runtime
  Target RID (default win-x64).

.PARAMETER Configuration
  MSBuild configuration (default Release).
#>
param(
    [string]$Version = "0.1.0",
    [string]$Runtime = "win-x64",
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

# Prefer a user-local SDK when Program Files\dotnet has host-only (no SDK).
$localDotnet = Join-Path $env:LOCALAPPDATA "Microsoft\dotnet\dotnet.exe"
if (Test-Path $localDotnet) {
    $env:DOTNET_ROOT = Split-Path $localDotnet -Parent
    $env:PATH = "$env:DOTNET_ROOT;$env:USERPROFILE\.dotnet\tools;$env:PATH"
} else {
    $env:PATH = "$env:USERPROFILE\.dotnet\tools;$env:PATH"
}

function Assert-DotnetSdk {
    $sdks = & dotnet --list-sdks 2>$null
    if (-not $sdks) {
        Write-Error @"
No .NET SDK found. Install .NET 8 SDK from https://aka.ms/dotnet/download
then close and reopen this terminal.

If you already installed a user-local SDK, run:
  `$env:DOTNET_ROOT = `"`$env:LOCALAPPDATA\Microsoft\dotnet`"
  `$env:PATH = `"`$env:DOTNET_ROOT;`$env:USERPROFILE\.dotnet\tools;`$env:PATH`"
"@
    }
    Write-Host "Using SDK:"
    $sdks | ForEach-Object { Write-Host "  $_" }
}

Assert-DotnetSdk

# windows/scripts → repo root
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$appProj = Join-Path $root "windows\src\PalmierPro.App\PalmierPro.App.csproj"
$publishDir = Join-Path $root "windows\artifacts\publish\$Runtime"
$packDir = Join-Path $root "windows\artifacts\velopack"
$feedUrl = "https://github.com/palmier-io/palmier-pro/releases/latest/download"

Write-Host "Publishing $appProj ($Configuration|$Runtime)..."
dotnet publish $appProj -c $Configuration -r $Runtime --self-contained true -o $publishDir /p:Version=$Version
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$mainExe = Join-Path $publishDir "PalmierPro.exe"
$coreDll = Join-Path $publishDir "PalmierPro.Core.dll"
foreach ($required in @($mainExe, $coreDll)) {
    if (-not (Test-Path $required)) {
        Write-Error "Publish smoke-check failed: missing $required"
    }
}
Write-Host "Publish smoke-check OK ($publishDir)"

$vpk = Get-Command vpk -ErrorAction SilentlyContinue
if (-not $vpk) {
    Write-Host "vpk not on PATH — trying: dotnet tool install -g vpk"
    $sources = & dotnet nuget list source 2>$null
    if (-not ($sources -match "nuget.org")) {
        dotnet nuget add source https://api.nuget.org/v3/index.json -n nuget.org | Out-Null
    }
    dotnet tool install -g vpk
    $env:PATH = "$env:USERPROFILE\.dotnet\tools;$env:PATH"
    $vpk = Get-Command vpk -ErrorAction SilentlyContinue
}

if (-not $vpk) {
    Write-Warning "vpk not found. Install with: dotnet tool install -g vpk"
    Write-Warning "Then reopen the terminal (tools PATH) and re-run this script."
    Write-Warning "Published bits are at $publishDir (packaging skipped)."
    Write-Host "You can still run: $mainExe"
    exit 0
}

Write-Host "Packaging with vpk ($($vpk.Source))..."
New-Item -ItemType Directory -Force -Path $packDir | Out-Null
& vpk pack --packId PalmierPro --packVersion $Version --packDir $publishDir --mainExe PalmierPro.exe --outputDir $packDir
if ($LASTEXITCODE -ne 0) {
    Write-Warning "vpk pack failed. Published bits are at $publishDir"
    exit $LASTEXITCODE
}

$setup = Get-ChildItem -Path $packDir -Filter "*Setup.exe" | Select-Object -First 1
if (-not $setup) {
    Write-Warning "Velopack output missing *Setup.exe under $packDir"
} else {
    Write-Host "Velopack smoke-check OK"
    Write-Host "Installer: $($setup.FullName)"
}
Write-Host "Velopack packages: $packDir"
Write-Host "Upload artifacts to update feed: $feedUrl"
Write-Host ""
Write-Host "To install locally, run the Setup.exe above."
