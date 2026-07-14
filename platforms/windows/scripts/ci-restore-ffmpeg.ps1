#Requires -Version 5.1
<#
.SYNOPSIS
    Restore the pinned prebuilt FFmpeg (BtbN GPL shared build) for CI.

.DESCRIPTION
    Reads platforms/windows/ffmpeg.lock.json for {url, sha256}. Until the real pin
    lands (milestone E1), both fields are "TBD" and this script is a no-op — it
    warns and exits 0 so CI doesn't block on a dependency that isn't wired up yet.
    Once pinned, it downloads to platforms/windows/third_party/ffmpeg/, verifies
    the sha256 (hard failure on mismatch — no silent use of an unverified build),
    and extracts.
#>

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

New-Item -ItemType Directory -Force -Path $ThirdPartyDir | Out-Null

$ArchivePath = Join-Path $ThirdPartyDir 'ffmpeg-download.zip'

Write-Host "Downloading FFmpeg from $($Lock.url)"
Invoke-WebRequest -Uri $Lock.url -OutFile $ArchivePath

Write-Host 'Verifying sha256'
$ActualHash = (Get-FileHash -Path $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
$ExpectedHash = $Lock.sha256.ToLowerInvariant()

if ($ActualHash -ne $ExpectedHash) {
    Remove-Item $ArchivePath -Force -ErrorAction SilentlyContinue
    Fail "sha256 mismatch.`n  expected: $ExpectedHash`n  actual:   $ActualHash`nRefusing to use an unverified FFmpeg build."
}

Write-Host 'sha256 verified. Extracting.'
Expand-Archive -Path $ArchivePath -DestinationPath $ThirdPartyDir -Force
Remove-Item $ArchivePath -Force

Write-Host "FFmpeg restored to $ThirdPartyDir"
