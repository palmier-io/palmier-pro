#Requires -Version 5.1
<#
.SYNOPSIS
    Build a complete, self-contained runnable payload for PalmierPro.App under
    platforms/windows/artifacts/publish/ — end users must not need the .NET runtime
    (or Visual Studio/MSBuild) installed to run it.

.DESCRIPTION
    One command:
      1. Resolve dotnet + msbuild (same discovery scripts/dev.ps1 uses).
      2. Restore FFmpeg if platforms/windows/third_party/ffmpeg is missing.
      3. Read (creating if absent) platforms/windows/VERSION — the single source
         version stamp also wired into every csproj's Version property via
         Directory.Build.props, and later into the installer.
      4. Build the native engine (Release|x64) via msbuild — vcxproj can't go
         through the dotnet CLI (MSB4278).
      5. `dotnet publish` PalmierPro.App as a self-contained win-x64 deployment.
         WindowsAppSDKSelfContained=true (already set in PalmierPro.App.csproj)
         only bundles the Windows App SDK/WinUI runtime — --self-contained true
         is the separate switch that bundles the .NET runtime itself
         (hostfxr/coreclr/System.*.dll), which is the actual "no .NET installed"
         requirement. ReadyToRun is left OFF for now (see note at the bottom):
         it would shrink cold-start JIT cost at the price of a larger, per-RID
         precompiled payload and a slower publish; revisit once startup time is
         a measured problem, not before.
      6. Verify the payload actually contains the native engine, FFmpeg DLLs,
         shaders, bundled fonts, and the CLR host — proving both "the engine
         payload survived publish" and "this is genuinely self-contained" in
         one pass. Fails loudly (naming the missing file) rather than shipping
         a payload that only half-runs.
      7. Copy THIRD_PARTY_NOTICES.md + the repo LICENSE next to the exe.

.EXAMPLE
    .\scripts\publish.ps1
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot                       # platforms/windows
$RepoTop = Split-Path -Parent (Split-Path -Parent $RepoRoot)       # repo root
$NativeProject = Join-Path $RepoRoot 'src\PalmierPro.Rendering\native\PalmierEngine.vcxproj'
$AppProject = Join-Path $RepoRoot 'src\PalmierPro.App\PalmierPro.App.csproj'
$VersionFile = Join-Path $RepoRoot 'VERSION'
$PublishDir = Join-Path $RepoRoot 'artifacts\publish'
$NoticesFile = Join-Path $RepoRoot 'THIRD_PARTY_NOTICES.md'
$LicenseFile = Join-Path $RepoTop 'LICENSE'

function Fail($message) {
    Write-Host ''
    Write-Host "publish.ps1: $message" -ForegroundColor Red
    exit 1
}

function Step($message) {
    Write-Host ''
    Write-Host "==> $message" -ForegroundColor Cyan
}

# --- Version -----------------------------------------------------------------

Step 'Resolving version'

if (-not (Test-Path $VersionFile)) {
    Set-Content -Path $VersionFile -Value '0.1.0' -NoNewline
    Write-Host "  Created $VersionFile (0.1.0)"
}

$Version = (Get-Content $VersionFile -Raw).Trim()
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    Fail "VERSION contains '$Version' — expected a plain MAJOR.MINOR.PATCH string (e.g. 0.1.0)."
}
Write-Host "  Version: $Version (Directory.Build.props reads this same file for the csproj Version property)"

# --- Resolve dotnet ------------------------------------------------------------

Step 'Resolving dotnet'

$LocalAppDataDotnet = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet\dotnet.exe'
if (Test-Path $LocalAppDataDotnet) {
    $DotnetExe = $LocalAppDataDotnet
    $env:DOTNET_ROOT = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
    $env:PATH = "$env:DOTNET_ROOT;$env:PATH"
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

# --- Locate msbuild via vswhere -------------------------------------------------

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

# --- Restore FFmpeg if missing ---------------------------------------------------

$FfmpegMarker = Join-Path $RepoRoot 'third_party\ffmpeg\bin\ffmpeg.exe'
if (-not (Test-Path $FfmpegMarker)) {
    Step 'Restoring FFmpeg (third_party/ffmpeg missing)'
    & (Join-Path $RepoRoot 'scripts\ci-restore-ffmpeg.ps1')
    if ($LASTEXITCODE -ne 0) {
        Fail "FFmpeg restore failed (exit $LASTEXITCODE). See output above."
    }
}

# --- Build native engine (Release|x64) ------------------------------------------

Step 'Building PalmierEngine.vcxproj (Release|x64)'

& $MsBuildPath $NativeProject -p:Configuration=Release -p:Platform=x64 -nologo -verbosity:minimal
if ($LASTEXITCODE -ne 0) {
    Fail "Native engine build failed (msbuild exit $LASTEXITCODE). See output above."
}

# --- Publish PalmierPro.App (self-contained win-x64) -----------------------------

Step "Publishing PalmierPro.App $Version (Release|win-x64, self-contained)"

if (Test-Path $PublishDir) {
    Remove-Item $PublishDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $PublishDir | Out-Null

& $DotnetExe publish $AppProject `
    -c Release `
    -r win-x64 `
    --self-contained true `
    -p:Platform=x64 `
    -o $PublishDir
if ($LASTEXITCODE -ne 0) {
    Fail "dotnet publish failed (exit $LASTEXITCODE). See output above."
}

# --- Verify payload completeness --------------------------------------------------
# The Content-staging in PalmierPro.Rendering.csproj / PalmierPro.App.csproj is what
# carries the native engine, FFmpeg DLLs, shaders, and fonts through a normal `dotnet
# build`; publish uses a different (output-copy) pipeline, so re-verify here rather
# than assume it survived unchanged.

Step 'Verifying published payload'

function Test-PayloadPath($relative, $description) {
    $full = Join-Path $PublishDir $relative
    if (-not (Test-Path $full)) {
        return "missing $description : $relative"
    }
    return $null
}

function Test-PayloadGlob($pattern, $description) {
    $matches = Get-ChildItem -Path $PublishDir -Filter $pattern -File -ErrorAction SilentlyContinue
    if (-not $matches -or $matches.Count -eq 0) {
        return "missing $description : $pattern"
    }
    return $null
}

$missing = @()

# The app itself, and proof the .NET runtime is bundled (self-contained), not just
# the Windows App SDK (WindowsAppSDKSelfContained=true bundles WinUI, not the CLR).
$missing += Test-PayloadPath 'PalmierPro.App.exe' 'app executable'
$missing += Test-PayloadPath 'hostfxr.dll' '.NET host resolver (proves --self-contained true actually bundled the runtime)'
$missing += Test-PayloadPath 'coreclr.dll' '.NET runtime (proves --self-contained true actually bundled the runtime)'

# Compiled XAML + the app's resource index — `dotnet publish` drops these by default
# (see PalmierPro.App.csproj's IncludeWinUIXamlOutputInPublish target); without them the
# app crashes on its first ms-appx:/// resource load instead of starting.
$missing += Test-PayloadPath 'App.xbf' 'compiled root XAML'
$missing += Test-PayloadPath 'Views\HomeView.xbf' 'compiled XAML (spot check)'
$missing += Test-PayloadPath 'PalmierPro.App.pri' 'app resource index'

# Native engine + its FFmpeg dependencies (PalmierPro.Rendering.csproj Content items).
$missing += Test-PayloadPath 'PalmierEngine.dll' 'native rendering/audio engine'
$missing += Test-PayloadGlob 'avformat-*.dll' 'FFmpeg avformat'
$missing += Test-PayloadGlob 'avcodec-*.dll' 'FFmpeg avcodec'
$missing += Test-PayloadGlob 'avutil-*.dll' 'FFmpeg avutil'
$missing += Test-PayloadGlob 'swscale-*.dll' 'FFmpeg swscale'
$missing += Test-PayloadGlob 'swresample-*.dll' 'FFmpeg swresample'

# HLSL shaders D3DCompile'd at runtime next to PalmierEngine.dll (GpuCompositor::ResolveShadersDir).
$shadersDir = Join-Path $PublishDir 'shaders'
if (-not (Test-Path $shadersDir) -or (Get-ChildItem $shadersDir -Filter '*.hlsl' -File -ErrorAction SilentlyContinue).Count -eq 0) {
    $missing += 'missing shaders : shaders\*.hlsl (0 files)'
}

# Engine-side bundled fonts (FontRegistry::ResolveFontsDir — text-clip compositing).
$engineFontsDir = Join-Path $PublishDir 'fonts'
if (-not (Test-Path $engineFontsDir) -or (Get-ChildItem $engineFontsDir -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0) {
    $missing += 'missing engine-side bundled fonts : fonts\**\*.ttf (0 files)'
}

# XAML-side bundled fonts (PalmierPro.App.csproj Content Link items — FontPicker/UI chrome).
$xamlFontsDir = Join-Path $PublishDir 'Assets\Fonts'
if (-not (Test-Path $xamlFontsDir) -or (Get-ChildItem $xamlFontsDir -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0) {
    $missing += 'missing XAML-side bundled fonts : Assets\Fonts\**\*.ttf (0 files)'
}

$missing = $missing | Where-Object { $_ }
if ($missing.Count -gt 0) {
    $list = ($missing | ForEach-Object { "  - $_" }) -join "`n"
    Fail @"
Published payload is incomplete:
$list

If this is a Content-staging item, check the Content ItemGroups in
PalmierPro.Rendering.csproj / PalmierPro.App.csproj — publish uses a
different output-copy pipeline than plain `dotnet build` and can drop items
that aren't marked CopyToPublishDirectory (CopyToOutputDirectory alone is not
always enough for `dotnet publish`).
"@
}

Write-Host '  All required payload files present (engine, FFmpeg, shaders, fonts, CLR host).'

# --- Copy licensing docs -----------------------------------------------------------

Step 'Copying THIRD_PARTY_NOTICES.md + LICENSE'

if (-not (Test-Path $NoticesFile)) {
    Fail "THIRD_PARTY_NOTICES.md not found at '$NoticesFile'."
}
if (-not (Test-Path $LicenseFile)) {
    Fail "LICENSE not found at '$LicenseFile'."
}
Copy-Item $NoticesFile -Destination $PublishDir -Force
Copy-Item $LicenseFile -Destination $PublishDir -Force

# --- Summary -------------------------------------------------------------------

$allFiles = Get-ChildItem -Path $PublishDir -Recurse -File
$totalBytes = ($allFiles | Measure-Object -Property Length -Sum).Sum
$totalMb = [Math]::Round($totalBytes / 1MB, 1)

Step 'Publish complete'
Write-Host "  Version:      $Version"
Write-Host "  Output:       $PublishDir"
Write-Host "  Files:        $($allFiles.Count)"
Write-Host "  Payload size: $totalMb MB"
Write-Host ''
Write-Host "  Run: $PublishDir\PalmierPro.App.exe"
