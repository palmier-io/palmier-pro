# Windows ↔ Mac feature parity

Status: **complete** for filmmaker + Agent contract parity and Default five-pane UI chrome.
Pixel-perfect SwiftUI clone was never a goal.

## Automated verification

```powershell
dotnet test windows/tests/PalmierPro.Agent.Tests
dotnet test windows/tests/PalmierPro.Core.Tests
dotnet build windows/src/PalmierPro.App/PalmierPro.App.csproj -p:Platform=x64
```

Last known green: Agent **26**, Core **206**, App build clean.

Covered in tests among others: Mac-shaped `get_timeline` / mutation deltas / timeline `get_transcript`, caption-group modal+deviant folding, BWF timecode reader.

## Platform substitutes (intentional)

| Mac | Windows |
|---|---|
| Speech framework STT | Whisper ONNX (+ Silero VAD) |
| SigLIP via MLX | Optional `siglip.onnx`, else `FrameFeatureEmbed` |
| DeepFilterNet3 (MLX) | Spectral-gate denoise (DeepFilter ONNX I/O not packaged) |
| ProRes export | Refused (Media Foundation) |
| Mezzanine / HDR | High-bitrate HEVC SDR |
| QuickTime `tmcd` | BWF + Sony `rtmd`; else `sync_clips mode=audio` |

Optional models: `powershell -ExecutionPolicy Bypass -File windows/scripts/fetch-models.ps1` (Whisper/Silero); `-Extra` for optional ONNX paths under `windows/models/` or `%LocalAppData%\PalmierPro\models\`.

## Contract deltas kept on purpose

- `organize_media action=nest|unnest` — Windows Agent convenience; Mac nests via UI / `add_clips` with a timeline id.
- `manage_tracks` `add` — Windows allows explicit add; Mac creates tracks via placement.
- Preview format chips on transport — Mac keeps format primarily in Inspector (Windows Inspector Settings are also editable).
