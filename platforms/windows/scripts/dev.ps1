#Requires -Version 5.1
<#
.SYNOPSIS
    Build the native engine, build the solution, and launch PalmierPro.App.

.DESCRIPTION
    Mirrors the CI steps in .github/workflows/ci.yml but for local inner-loop dev:
    the native PalmierEngine.vcxproj is NOT in PalmierPro.sln (dotnet CLI cannot
    build vcxproj — MSB4278) so it's built here via a separate msbuild invocation.
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot   # platforms/windows
$NativeProject = Join-Path $RepoRoot 'src\PalmierPro.Rendering\native\PalmierEngine.vcxproj'
$SolutionPath = Join-Path $RepoRoot 'PalmierPro.sln'
$AppProject = Join-Path $RepoRoot 'src\PalmierPro.App\PalmierPro.App.csproj'

function Fail($message) {
    Write-Host ''
    Write-Host "dev.ps1: $message" -ForegroundColor Red
    exit 1
}

function Step($message) {
    Write-Host ''
    Write-Host "==> $message" -ForegroundColor Cyan
}

# --- Resolve dotnet ---------------------------------------------------------

Step 'Resolving dotnet'

$LocalAppDataDotnet = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'
if (Test-Path $LocalAppDataDotnet) {
    $DotnetExe = $LocalAppDataDotnet
    $env:DOTNET_ROOT = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
    Write-Host "  Using per-user install: $DotnetExe"
    Write-Host "  DOTNET_ROOT = $env:DOTNET_ROOT"
} else {
    $Command = Get-Command dotnet.exe -ErrorAction SilentlyContinue
    if (-not $Command) {
        Fail @"
Could not find dotnet.
  - Checked $LocalAppDataDotnet (not found)
  - Checked PATH (not found)
Install the .NET 10 SDK: https://dotnet.microsoft.com/download/dotnet/10.0
"@
    }
    $DotnetExe = $Command.Source
    Write-Host "  Using PATH install: $DotnetExe"
}

& $DotnetExe --version | Out-Null
if ($LASTEXITCODE -ne 0) {
    Fail "dotnet was found at '$DotnetExe' but 'dotnet --version' failed (exit $LASTEXITCODE)."
}

# --- Locate msbuild via vswhere ---------------------------------------------

Step 'Locating msbuild (vswhere)'

$VsWhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $VsWhere)) {
    Fail @"
vswhere.exe not found at '$VsWhere'.
Install Visual Studio 2022 (or Build Tools for Visual Studio 2022) with the
'Desktop development with C++' workload — it's required to build PalmierEngine.vcxproj.
"@
}

$MsBuildPath = & $VsWhere -latest -prerelease -products * `
    -requires Microsoft.Component.MSBuild `
    -find 'MSBuild\**\Bin\MSBuild.exe' | Select-Object -First 1

if (-not $MsBuildPath -or -not (Test-Path $MsBuildPath)) {
    Fail @"
vswhere could not locate MSBuild.
Install Visual Studio 2022 (or Build Tools for Visual Studio 2022) with the
'Desktop development with C++' workload, which installs MSBuild + the v143 toolset.
"@
}

Write-Host "  Using: $MsBuildPath"

# --- Restore FFmpeg if missing ------------------------------------------------

$FfmpegMarker = Join-Path $RepoRoot 'third_party\ffmpeg\bin\ffmpeg.exe'
if (-not (Test-Path $FfmpegMarker)) {
    Step 'Restoring FFmpeg (third_party/ffmpeg missing)'
    & (Join-Path $RepoRoot 'scripts\ci-restore-ffmpeg.ps1')
    if ($LASTEXITCODE -ne 0) {
        Fail "FFmpeg restore failed (exit $LASTEXITCODE). See output above."
    }
}

# --- Build native engine (x64 Debug) ----------------------------------------

Step 'Building PalmierEngine.vcxproj (Debug|x64)'

& $MsBuildPath $NativeProject -p:Configuration=Debug -p:Platform=x64 -nologo -verbosity:minimal
if ($LASTEXITCODE -ne 0) {
    Fail "Native engine build failed (msbuild exit $LASTEXITCODE). See output above."
}

# --- dotnet build the solution ----------------------------------------------

Step 'Building PalmierPro.sln (Debug|x64)'

& $DotnetExe build $SolutionPath -c Debug -p:Platform=x64
if ($LASTEXITCODE -ne 0) {
    Fail "dotnet build failed (exit $LASTEXITCODE). See output above."
}

# --- Run the app -------------------------------------------------------------

Step 'Launching PalmierPro.App'

& $DotnetExe run --project $AppProject -c Debug
if ($LASTEXITCODE -ne 0) {
    Fail "dotnet run failed (exit $LASTEXITCODE). See output above."
}
