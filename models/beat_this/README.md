# Beat This - beat detection

[Beat This](https://github.com/CPJKU/beat_this) is a model that tracks neural
beat/downbeat. Runs fully on-device; the compiled model is bundled in
the app at `Sources/PalmierPro/Resources/Models/BeatThis.mlmodelc` (6.6 MB).

## The model

Beat This `small0` (https://github.com/CPJKU/beat_this — "Beat This! Accurate
Beat Tracking Without DBN Postprocessing", ISMIR 2024). The log-mel frontend is
folded into the Core ML graph: input is raw PCM (661059 samples = 30s at
22050 Hz mono), outputs are framewise beat/downbeat logits (1, 1500), 20 ms per
frame. FP16.

## Building

```
uv venv --python 3.12 .venv
uv pip install -p .venv/bin/python -r requirements.txt
.venv/bin/python convert.py --out build
```

The checkpoint downloads automatically (torch.hub cache). The script rewrites
the model's einops ops to native tensor ops (coremltools rejects the runtime-int
ops einops emits), traces with torch.jit, and converts. It aborts unless two
parity gates pass on a 120 BPM click fixture: the patched torch model must place
beats identically to the unmodified upstream pipeline (1-frame tolerance), and
the Core ML model identically to the patched torch model.

Copy `build/BeatThis.mlmodelc` into `Sources/PalmierPro/Resources/Models/`.

## Runtime contract

Longer audio is chunked with a 6-frame border discard and keep-first stitching;
peak-picking is sigmoid ≥ 0.5 + local max (the model needs no DBN). Outputs are
FP16 multiarrays — read as Float16. See `Sources/PalmierPro/Audio/Beats/BeatDetector.swift`.

## License

MIT, same as the upstream code and weights.
