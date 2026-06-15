---
license: apache-2.0
base_model: google/siglip2-base-patch16-256
tags:
  - coreml
  - siglip2
  - image-text-retrieval
library_name: coreml
---

# SigLIP 2 B/16-256 — Core ML

Core ML conversion of [google/siglip2-base-patch16-256](https://huggingface.co/google/siglip2-base-patch16-256),
split into separate image and text encoders for on-device text→image retrieval.
Built for [Palmier Pro](https://palmier.io)'s footage search; usable by anything
that wants SigLIP 2 on Apple silicon.

## Files

| File | Contents |
|---|---|
| `ImageEncoder.mlpackage.zip` | Vision tower, 256×256 input, 8-bit palettized (per-grouped-channel) |
| `TextEncoder.mlpackage.zip` | Text tower, 64-token input, 8-bit palettized |
| `tokenizer.zip` | Gemma SentencePiece tokenizer files (`tokenizer.json`, config) |
| `manifest.json` | File names, sha256s, sizes, model dims |

Both encoders emit L2-normalized 768-d embeddings (`embedding` output); similarity
is a plain dot product. Minimum deployment target: macOS 15.

## Usage notes

- Image preprocessing is a **squash-resize** to 256×256 (no center crop), pixels
  scaled to [-1, 1]. The `ImageType` input already applies the scaling.
- Text must be tokenized with the bundled Gemma tokenizer and **padded to 64
  with the pad token (0), no attention mask** — SigLIP was trained that way and
  embeddings drift if padding differs.
- Conversion is parity-gated: every release's embeddings match the PyTorch
  reference at cosine ≥ 0.99 on a fixture set. Conversion source:
  [palmier-io/palmier-pro `models/siglip2`](https://github.com/palmier-io).

## Versioning

Files in this repo are immutable once published. Re-conversions are published as
new versions, never overwrites.

## License

Apache 2.0, same as the original weights by Google. This repository redistributes
a converted form of those weights without modification to their values beyond
8-bit palettization.
