This folder contains the code to build Core ML of CLIP model used inside the swift app.

## Semantic search

We use CLIP model to empower visual search in our video editor, where agents and users can search
through footage with CLIP model running locally. The model is downloaded during runtime and
not bundled in the app.

## The model

We use SigLIP 2 (https://huggingface.co/google/siglip2-base-patch16-256) by Google, and run with
Core ML framework by Apple (https://developer.apple.com/documentation/coreml)

## Building the Core ML packages

There's no official Core ML build, so we convert it ourselves:

```
cd siglip2
uv venv --python 3.12 .venv
uv pip install -p .venv/bin/python -r requirements.txt
.venv/bin/python convert.py --checkpoint checkpoint --out build-q8 --palettize-bits 8
```

(See convert.py for how to fetch the checkpoint first.) The script traces both
encoders to .mlpackage, quantizes to 8-bit, and aborts unless the converted
model's embeddings match PyTorch's (cosine ≥ 0.99). `export_tokenizer.py`
regenerates the Swift tokenizer golden tests.

## Hosting

The build output (two encoder zips, tokenizer.zip, manifest.json) is uploaded to
huggingface.co/palmier-io/siglip2-base-coreml.

## Download

The app downloads the artifacts from the repo above on first use and verifies
them against the sha256s pinned in SearchIndexConfig.swift, which is also where
the URL lives.

## License

SigLIP 2 weights are Apache 2.0 (Google); our converted artifacts are
redistributed under the same terms, with attribution in the HF model card.
