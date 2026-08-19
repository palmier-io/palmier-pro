# On-device ML models

| File | Purpose |
|------|---------|
| `ggml-tiny.bin` | Whisper.cpp tiny model for local STT |
| `silero_vad.onnx` | Silero VAD for `remove_silence` |
| `siglip.onnx` | Optional SigLIP visual embeddings (`-Extra`) |
| `deepfilter.onnx` | Optional DeepFilter denoise (`-Extra`) |
| `beat.onnx` / `speaker.onnx` | Optional analysis stubs (`-Extra`) |

Fetch:

```powershell
powershell -ExecutionPolicy Bypass -File windows/scripts/fetch-models.ps1
powershell -ExecutionPolicy Bypass -File windows/scripts/fetch-models.ps1 -Extra   # optional ONNX; failures are non-fatal
```

Or set `PALMIER_WHISPER_MODEL` / `PALMIER_SILERO_MODEL` (and `PALMIER_SIGLIP_MODEL` / `PALMIER_DEEPFILTER_MODEL`) to absolute paths.

The app also auto-downloads Whisper/Silero into `%LocalAppData%\PalmierPro\models\` on first use when bundled files are missing.
