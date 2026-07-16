#Requires -Version 5.1
<#
.SYNOPSIS
    Build the PalmierPro Windows installer (Stage E2): publish + Inno Setup, one command.

.DESCRIPTION
    1. Runs scripts/publish.ps1 to produce the self-contained payload under
       artifacts/publish/ (fails loudly there if the payload is incomplete —
       this script doesn't re-check it).
    2. Resolves ISCC.exe (Inno Setup 6's command-line compiler): checks the
       usual install locations and PATH; if absent, installs Inno Setup 6 via
       winget, falling back to downloading the official installer directly
       and running it /VERYSILENT /CURRENTUSER if winget itself is unavailable
       or fails. Re-resolves after either install path.
    3. Reads platforms/windows/VERSION and compiles
       installer/PalmierPro.iss with -DAppVersion=<version>, producing
       artifacts/installer/PalmierProSetup-<version>.exe.

.EXAMPLE
    .\scripts\build-installer.ps1
#>

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot                       # platforms/windows
$VersionFile = Join-Path $RepoRoot 'VERSION'
$IssFile = Join-Path $RepoRoot 'installer\PalmierPro.iss'
$InstallerDir = Join-Path $RepoRoot 'artifacts\installer'

function Fail($message) {
    Write-Host ''
    Write-Host "build-installer.ps1: $message" -ForegroundColor Red
    exit 1
}

function Step($message) {
    Write-Host ''
    Write-Host "==> $message" -ForegroundColor Cyan
}

# --- Publish the self-contained payload ---------------------------------------

Step 'Running publish.ps1'

& (Join-Path $PSScriptRoot 'publish.ps1')
if ($LASTEXITCODE -ne 0) {
    Fail "publish.ps1 failed (exit $LASTEXITCODE). See output above."
}

# --- Resolve ISCC.exe (Inno Setup 6) --------------------------------------------

Step 'Resolving ISCC.exe (Inno Setup 6)'

function Find-Iscc {
    $pf86 = ${env:ProgramFiles(x86)}
    $candidates = @(
        (Join-Path $pf86 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
    )
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path $candidate)) {
            return $candidate
        }
    }
    $onPath = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($onPath) {
        return $onPath.Source
    }
    return $null
}

$IsccExe = Find-Iscc

if (-not $IsccExe) {
    Step 'Inno Setup 6 not found — installing via winget'

    $Winget = Get-Command winget -ErrorAction SilentlyContinue
    $WingetOk = $false
    if ($Winget) {
        & winget install JRSoftware.InnoSetup --silent --accept-source-agreements --accept-package-agreements
        $WingetOk = ($LASTEXITCODE -eq 0)
        if (-not $WingetOk) {
            Write-Host "  winget install exited $LASTEXITCODE — falling back to direct download." -ForegroundColor Yellow
        }
    } else {
        Write-Host '  winget not found on PATH — falling back to direct download.' -ForegroundColor Yellow
    }

    $IsccExe = Find-Iscc

    if (-not $IsccExe) {
        Step 'Downloading Inno Setup 6 installer directly'

        $Downloader = Join-Path $env:TEMP 'innosetup-installer.exe'
        try {
            Invoke-WebRequest -Uri 'https://jrsoftware.org/download.php/is.exe' -OutFile $Downloader -UseBasicParsing
        } catch {
            Fail "Could not download the Inno Setup installer: $($_.Exception.Message)`nInstall it manually from https://jrsoftware.org/isinfo.php and re-run this script."
        }

        & $Downloader /VERYSILENT /CURRENTUSER
        if ($LASTEXITCODE -ne 0) {
            Fail "Inno Setup installer exited $LASTEXITCODE. Install it manually from https://jrsoftware.org/isinfo.php and re-run this script."
        }

        $IsccExe = Find-Iscc
    }

    if (-not $IsccExe) {
        Fail @"
Inno Setup 6 was installed but ISCC.exe still could not be located.
Checked:
  - Program Files (x86)\Inno Setup 6\ISCC.exe
  - Program Files\Inno Setup 6\ISCC.exe
  - %LOCALAPPDATA%\Programs\Inno Setup 6\ISCC.exe
  - PATH
Install Inno Setup 6 manually (https://jrsoftware.org/isinfo.php) and re-run this script.
"@
    }
}

Write-Host "  Using: $IsccExe"

# --- Version ---------------------------------------------------------------------

Step 'Resolving version'

if (-not (Test-Path $VersionFile)) {
    Fail "VERSION not found at '$VersionFile' — run publish.ps1 first (it creates one)."
}
$Version = (Get-Content $VersionFile -Raw).Trim()
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    Fail "VERSION contains '$Version' — expected a plain MAJOR.MINOR.PATCH string (e.g. 0.1.0)."
}
Write-Host "  Version: $Version"

# --- Compile the installer --------------------------------------------------------

Step "Compiling installer/PalmierPro.iss ($Version)"

New-Item -ItemType Directory -Force -Path $InstallerDir | Out-Null

& $IsccExe "/DAppVersion=$Version" $IssFile
if ($LASTEXITCODE -ne 0) {
    Fail "ISCC.exe failed (exit $LASTEXITCODE). See output above."
}

# --- Summary -----------------------------------------------------------------------

$SetupExe = Join-Path $InstallerDir "PalmierProSetup-$Version.exe"
if (-not (Test-Path $SetupExe)) {
    Fail "Expected output not found at '$SetupExe' — check the ISCC.exe output above for the actual OutputBaseFilename used."
}
$SetupSizeMb = [Math]::Round((Get-Item $SetupExe).Length / 1MB, 1)

Step 'Installer build complete'
Write-Host "  Version: $Version"
Write-Host "  Output:  $SetupExe"
Write-Host "  Size:    $SetupSizeMb MB"
Write-Host ''
Write-Host "  Silent install:  $SetupExe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
Write-Host "  Interactive:     $SetupExe"
