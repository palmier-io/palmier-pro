# Downloads on-device ML assets into windows/models/ for Whisper STT + Silero VAD.
# Usage:
#   pwsh -File windows/scripts/fetch-models.ps1
#   pwsh -File windows/scripts/fetch-models.ps1 -Size base
#   pwsh -File windows/scripts/fetch-models.ps1 -Size small
#   pwsh -File windows/scripts/fetch-models.ps1 -Extra
# Env overrides: PALMIER_WHISPER_MODEL_URL, PALMIER_SILERO_MODEL_URL
# Optional extras (do not fail the script): PALMIER_SIGLIP_MODEL_URL, PALMIER_DEEPFILTER_MODEL_URL,
#   PALMIER_BEAT_MODEL_URL, PALMIER_SPEAKER_MODEL_URL

param(
    [ValidateSet("tiny", "base", "small")]
    [string]$Size = "tiny",
    [switch]$Extra
)

$ErrorActionPreference = "Stop"
$root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if (-not (Test-Path (Join-Path $root "windows"))) {
    $root = Split-Path $PSScriptRoot -Parent
}
$models = Join-Path $root "windows\models"
New-Item -ItemType Directory -Force -Path $models | Out-Null

$whisperFile = "ggml-$Size.bin"
$whisperUrl = $env:PALMIER_WHISPER_MODEL_URL
if (-not $whisperUrl) {
    $whisperUrl = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$whisperFile"
}
$sileroUrl = $env:PALMIER_SILERO_MODEL_URL
if (-not $sileroUrl) {
    $sileroUrl = "https://github.com/snakers4/silero-vad/raw/master/src/silero_vad/data/silero_vad.onnx"
}

function Get-Model([string]$Url, [string]$Dest, [string]$Label, [switch]$Optional) {
    if (Test-Path $Dest) {
        Write-Host "OK  $Label already present: $Dest"
        return
    }
    Write-Host "GET $Label from $Url"
    $tmp = "$Dest.partial"
    try {
        Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
        Move-Item -Force $tmp $Dest
        Write-Host "OK  $Label -> $Dest ($((Get-Item $Dest).Length) bytes)"
    }
    catch {
        if (Test-Path $tmp) { Remove-Item -Force $tmp }
        if ($Optional) {
            Write-Warning "Optional $Label skipped: $_"
            return
        }
        Write-Warning "Failed $Label : $_"
        throw
    }
}

Get-Model $whisperUrl (Join-Path $models $whisperFile) "Whisper $whisperFile"
Get-Model $sileroUrl (Join-Path $models "silero_vad.onnx") "Silero VAD"

if ($Extra) {
    Write-Host ""
    Write-Host "Fetching optional ONNX extras (failures are non-fatal)…"
    # Documented placeholders — set env URLs to real hosted weights when available.
    $siglip = $env:PALMIER_SIGLIP_MODEL_URL
    if (-not $siglip) { $siglip = "https://example.invalid/palmier/siglip.onnx" }
    $deepfilter = $env:PALMIER_DEEPFILTER_MODEL_URL
    if (-not $deepfilter) { $deepfilter = "https://example.invalid/palmier/deepfilter.onnx" }
    $beat = $env:PALMIER_BEAT_MODEL_URL
    if (-not $beat) { $beat = "https://example.invalid/palmier/beat.onnx" }
    $speaker = $env:PALMIER_SPEAKER_MODEL_URL
    if (-not $speaker) { $speaker = "https://example.invalid/palmier/speaker.onnx" }

    Get-Model $siglip (Join-Path $models "siglip.onnx") "SigLIP" -Optional
    Get-Model $deepfilter (Join-Path $models "deepfilter.onnx") "DeepFilter" -Optional
    Get-Model $beat (Join-Path $models "beat.onnx") "Beat tracker" -Optional
    Get-Model $speaker (Join-Path $models "speaker.onnx") "Speaker embed" -Optional
}

Write-Host ""
Write-Host "Models ready under $models"
Write-Host "Set Whisper size in Settings → Agent (WhisperModelSize=$Size), or PALMIER_WHISPER_MODEL."
Write-Host "Optional ONNX: -Extra (or place siglip.onnx / deepfilter.onnx / beat.onnx / speaker.onnx under models/)."
