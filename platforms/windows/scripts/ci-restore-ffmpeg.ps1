#Requires -Version 5.1
<#
.SYNOPSIS
    Restore the pinned prebuilt FFmpeg (BtbN GPL shared build) for CI/local dev.

.DESCRIPTION
    Reads platforms/windows/ffmpeg.lock.json for {url, sha256, archiveRootDir}.
    Downloads to a temp file, verifies sha256 (hard failure on mismatch — no silent
    use of an unverified build), and extracts to platforms/windows/third_party/ffmpeg/
    with a stable layout (bin/, include/, lib/ directly under third_party/ffmpeg —
    the archive's own versioned top-level folder is flattened away so callers never
    need to know the pinned version string).

    Idempotent: skips the download+extract if third_party/ffmpeg already contains
    bin/ffmpeg.exe (pass -Force to redo it anyway, e.g. after re-pinning).
#>

param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot   # platforms/windows
$LockPath = Join-Path $RepoRoot 'ffmpeg.lock.json'
$ThirdPartyDir = Join-Path $RepoRoot 'third_party\ffmpeg'

function Fail($message) {
    Write-Host ''
    Write-Host "ci-restore-ffmpeg.ps1: $message" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $LockPath)) {
    Fail "Lock file not found at '$LockPath'."
}

$Lock = Get-Content $LockPath -Raw | ConvertFrom-Json

if ($Lock.url -eq 'TBD' -or $Lock.sha256 -eq 'TBD') {
    Write-Host ''
    Write-Warning "ffmpeg.lock.json is still unpinned (url/sha256 = TBD). Skipping FFmpeg restore — no-op until milestone E1."
    exit 0
}

$MarkerPath = Join-Path $ThirdPartyDir 'bin\ffmpeg.exe'
if ((Test-Path $MarkerPath) -and -not $Force) {
    Write-Host "FFmpeg already restored at $ThirdPartyDir (use -Force to re-restore)."
    exit 0
}

if (Test-Path $ThirdPartyDir) {
    Remove-Item $ThirdPartyDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $ThirdPartyDir | Out-Null

$DownloadDir = Join-Path ([System.IO.Path]::GetTempPath()) ("palmier-ffmpeg-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
$ArchivePath = Join-Path $DownloadDir 'ffmpeg-download.zip'

try {
    Write-Host "Downloading FFmpeg from $($Lock.url)"
    $ProgressPreference = 'SilentlyContinue'   # Invoke-WebRequest's default progress bar is extremely slow in CI
    Invoke-WebRequest -Uri $Lock.url -OutFile $ArchivePath
    $ProgressPreference = 'Continue'

    Write-Host 'Verifying sha256'
    $ActualHash = (Get-FileHash -Path $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $ExpectedHash = $Lock.sha256.ToLowerInvariant()

    if ($ActualHash -ne $ExpectedHash) {
        Fail "sha256 mismatch.`n  expected: $ExpectedHash`n  actual:   $ActualHash`nRefusing to use an unverified FFmpeg build."
    }

    Write-Host 'sha256 verified. Extracting.'
    $ExtractStaging = Join-Path $DownloadDir 'extracted'
    Expand-Archive -Path $ArchivePath -DestinationPath $ExtractStaging -Force

    # The archive contains a single versioned top-level directory (e.g.
    # ffmpeg-n8.1.2-...-win64-gpl-shared-8.1/{bin,include,lib,...}); flatten it so
    # third_party/ffmpeg/{bin,include,lib} is a stable path regardless of pinned version.
    $ArchiveRoot = if ($Lock.archiveRootDir) {
        Join-Path $ExtractStaging $Lock.archiveRootDir
    } else {
        (Get-ChildItem -Path $ExtractStaging -Directory | Select-Object -First 1).FullName
    }

    if (-not (Test-Path $ArchiveRoot)) {
        Fail "Expected archive root '$ArchiveRoot' not found after extraction. The BtbN archive layout may have changed — update ffmpeg.lock.json's archiveRootDir."
    }

    Get-ChildItem -Path $ArchiveRoot -Force | Move-Item -Destination $ThirdPartyDir -Force
}
finally {
    Remove-Item $DownloadDir -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($required in @('bin\ffmpeg.exe', 'lib\avcodec.lib', 'lib\avformat.lib', 'lib\avutil.lib', 'lib\swscale.lib', 'lib\swresample.lib', 'include\libavcodec\avcodec.h')) {
    $p = Join-Path $ThirdPartyDir $required
    if (-not (Test-Path $p)) {
        Fail "Restored FFmpeg is missing expected file '$required'. Layout assumptions in this script may be stale — check the archive contents."
    }
}
if (-not (Get-ChildItem -Path (Join-Path $ThirdPartyDir 'bin') -Filter 'avcodec-*.dll' -ErrorAction SilentlyContinue)) {
    Fail "Restored FFmpeg is missing an avcodec-*.dll runtime in bin\. Layout assumptions in this script may be stale — check the archive contents."
}

Write-Host "FFmpeg restored to $ThirdPartyDir"
