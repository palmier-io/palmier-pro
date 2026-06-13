#!/usr/bin/env python3
"""Convert SigLIP 2 (fixed-resolution) to Core ML.

Fetch the checkpoint first (curl -4: the HF python downloader stalls over WARP IPv6):
  mkdir -p checkpoint && for f in config.json preprocessor_config.json tokenizer.json \
    tokenizer.model tokenizer_config.json special_tokens_map.json model.safetensors; do
    curl -sL -4 "https://huggingface.co/google/siglip2-base-patch16-256/resolve/main/$f" -o "checkpoint/$f"; done

Usage:
  python convert.py --checkpoint checkpoint/ --out build/ [--palettize-bits 8]
Outputs:
  build/<model>/ImageEncoder.mlpackage(.zip)
  build/<model>/TextEncoder.mlpackage(.zip)
  build/<model>/tokenizer.json
  build/<model>/manifest.json
  build/<model>/fixtures.json   (golden vectors + token ids for Swift parity tests)
"""

import argparse
import hashlib
import json
import zipfile
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image
from transformers import AutoModel, AutoTokenizer

MODEL_NAME = "siglip2-base-patch16-256"
CONTEXT_LENGTH = 64


def fixture_images(size):
    # Deterministic synthetic images so parity tests need no downloads.
    # A pure smooth gradient is degenerate (near-zero information; its embedding
    # amplifies any fp16 path difference), so the gradient gets texture mixed in.
    imgs = []
    rng = np.random.default_rng(seed=42)
    for i in range(4):
        arr = rng.integers(0, 256, (size, size, 3), dtype=np.uint8)
        if i == 0:
            gradient = np.linspace(0, 255, size)[None, :, None]
            arr = (0.7 * gradient + 0.3 * arr).astype(np.uint8)
        imgs.append(Image.fromarray(arr))
    return imgs


FIXTURE_TEXTS = [
    "a photo of a dog running on a beach",
    "a close-up of hands typing on a laptop",
    "an establishing shot of a city skyline at night",
    "a cat",
    "café exterior with neon sign",
]


class ImageTower(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, x):
        return torch.nn.functional.normalize(self.model.get_image_features(pixel_values=x), dim=-1)


class TextTower(torch.nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model

    def forward(self, tokens):
        return torch.nn.functional.normalize(self.model.get_text_features(input_ids=tokens), dim=-1)


def tokenize(tokenizer, text):
    # SigLIP was trained on max_length-padded sequences with no attention mask;
    # Swift must pad identically or embeddings drift.
    return tokenizer(
        [text], return_tensors="pt", padding="max_length",
        truncation=True, max_length=CONTEXT_LENGTH,
    ).input_ids


def convert_image_encoder(tower, image_size, out_dir):
    example = torch.rand(1, 3, image_size, image_size) * 2 - 1
    traced = torch.jit.trace(tower, example)
    # Preprocessing is squash-resize + (x/255 - 0.5)/0.5, i.e. pixels -> [-1, 1].
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 127.5, bias=[-1, -1, -1])],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS15,
        compute_units=ct.ComputeUnit.ALL,
    )
    path = out_dir / "ImageEncoder.mlpackage"
    mlmodel.save(str(path))
    return path


def convert_text_encoder(tower, tokenizer, out_dir):
    example = tokenize(tokenizer, "a photo of a dog").to(torch.int32)
    traced = torch.jit.trace(tower, example, check_trace=False)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="tokens", shape=example.shape, dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding")],
        minimum_deployment_target=ct.target.macOS15,
        compute_units=ct.ComputeUnit.ALL,
    )
    path = out_dir / "TextEncoder.mlpackage"
    mlmodel.save(str(path))
    return path


def parity_and_fixtures(image_tower, text_tower, tokenizer, image_path, text_path, image_size, out_dir):
    import coremltools.models

    ml_image = coremltools.models.MLModel(str(image_path))
    ml_text = coremltools.models.MLModel(str(text_path))

    fixtures = {"images": [], "texts": []}
    worst = 1.0

    for i, img in enumerate(fixture_images(image_size)):
        pixels = torch.from_numpy(np.asarray(img)).permute(2, 0, 1).float().unsqueeze(0) / 127.5 - 1
        with torch.no_grad():
            ref = image_tower(pixels).numpy()[0]
        got = ml_image.predict({"image": img})["embedding"][0]
        cos = float(np.dot(ref, got) / (np.linalg.norm(ref) * np.linalg.norm(got)))
        worst = min(worst, cos)
        print(f"  image[{i}] cosine(torch, coreml) = {cos:.5f}")
        img_file = out_dir / f"fixture_image_{i}.png"
        img.save(img_file)
        fixtures["images"].append({"file": img_file.name, "embedding": ref.astype(float).round(6).tolist()})

    for text in FIXTURE_TEXTS:
        tokens = tokenize(tokenizer, text)
        with torch.no_grad():
            ref = text_tower(tokens).numpy()[0]
        got = ml_text.predict({"tokens": tokens.numpy().astype(np.int32)})["embedding"][0]
        cos = float(np.dot(ref, got) / (np.linalg.norm(ref) * np.linalg.norm(got)))
        worst = min(worst, cos)
        print(f"  text {text!r:55s} cosine = {cos:.5f}")
        fixtures["texts"].append({
            "text": text,
            "tokens": tokens[0].tolist(),
            "embedding": ref.astype(float).round(6).tolist(),
        })

    (out_dir / "fixtures.json").write_text(json.dumps(fixtures))
    return worst


def palettize(path, nbits, granularity):
    from coremltools.optimize.coreml import (
        OpPalettizerConfig,
        OptimizationConfig,
        palettize_weights,
    )
    import coremltools.models

    # Image tower needs per-grouped-channel to pass parity; the text tower passes
    # per-tensor, and grouped kmeans on its 256k-vocab embedding table never finishes.
    kwargs = {"granularity": "per_grouped_channel", "group_size": 16} if granularity == "grouped" else {}
    mlmodel = coremltools.models.MLModel(str(path))
    config = OptimizationConfig(global_config=OpPalettizerConfig(mode="kmeans", nbits=nbits, **kwargs))
    palettize_weights(mlmodel, config).save(str(path))


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_entry(path):
    return {"name": path.name, "sha256": sha256(path), "bytes": path.stat().st_size}


def swift_manifest_literal(manifest):
    """The exact `ModelDownloader.Manifest(...)` literal for SearchIndexConfig.swift,
    so the pins are copy-pasted from the build, never hand-typed."""
    def entry(e):
        return (
            f"                name: \"{e['name']}\",\n"
            f"                sha256: \"{e['sha256']}\",\n"
            f"                bytes: {e['bytes']:_}\n"
        )
    f = manifest["files"]
    return (
        "    static let manifest = ModelDownloader.Manifest(\n"
        f"        model: \"{manifest['model']}\",\n"
        f"        version: {manifest['version']},\n"
        f"        embeddingDim: {manifest['embeddingDim']},\n"
        f"        imageSize: {manifest['imageSize']},\n"
        f"        contextLength: {manifest['contextLength']},\n"
        "        files: .init(\n"
        f"            imageEncoder: .init(\n{entry(f['imageEncoder'])}            ),\n"
        f"            textEncoder: .init(\n{entry(f['textEncoder'])}            ),\n"
        f"            tokenizer: .init(\n{entry(f['tokenizer'])}            )\n"
        "        )\n"
        "    )\n"
    )


def zip_package(pkg_path):
    zip_path = pkg_path.with_suffix(".mlpackage.zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(pkg_path.rglob("*")):
            if f.is_file():
                z.write(f, f.relative_to(pkg_path.parent))
    return zip_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", default="checkpoint")
    ap.add_argument("--out", default="build")
    ap.add_argument("--min-cosine", type=float, default=0.99)
    ap.add_argument("--palettize-bits", type=int, choices=[4, 6, 8])
    args = ap.parse_args()

    out_dir = Path(args.out) / MODEL_NAME
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"Loading {MODEL_NAME} from {args.checkpoint} ...")
    model = AutoModel.from_pretrained(args.checkpoint).eval()
    tokenizer = AutoTokenizer.from_pretrained(args.checkpoint)

    image_size = model.config.vision_config.image_size
    embed_dim = model.config.vision_config.hidden_size
    print(f"image_size={image_size} embed_dim={embed_dim} context_length={CONTEXT_LENGTH}")

    image_tower = ImageTower(model).eval()
    text_tower = TextTower(model).eval()

    print("Converting image encoder ...")
    image_path = convert_image_encoder(image_tower, image_size, out_dir)
    print("Converting text encoder ...")
    text_path = convert_text_encoder(text_tower, tokenizer, out_dir)

    if args.palettize_bits:
        print(f"Palettizing weights to {args.palettize_bits} bits ...")
        palettize(image_path, args.palettize_bits, granularity="grouped")
        palettize(text_path, args.palettize_bits, granularity="per_tensor")

    print("Parity check ...")
    worst = parity_and_fixtures(image_tower, text_tower, tokenizer, image_path, text_path, image_size, out_dir)
    print(f"worst cosine = {worst:.5f}")
    if worst < args.min_cosine:
        raise SystemExit(f"FAIL: parity below {args.min_cosine}")

    # swift-transformers loads a tokenizer from a folder of these files.
    tok_dir = out_dir / "tokenizer"
    tok_dir.mkdir(exist_ok=True)
    for name in ["tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"]:
        (tok_dir / name).write_bytes((Path(args.checkpoint) / name).read_bytes())
    tokenizer_zip = out_dir / "tokenizer.zip"
    with zipfile.ZipFile(tokenizer_zip, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(tok_dir.iterdir()):
            z.write(f, f"tokenizer/{f.name}")

    image_zip = zip_package(image_path)
    text_zip = zip_package(text_path)
    manifest = {
        "model": MODEL_NAME,
        "version": 1,
        "weights": f"palettized-{args.palettize_bits}bit" if args.palettize_bits else "fp16",
        "embeddingDim": embed_dim,
        "imageSize": image_size,
        "contextLength": CONTEXT_LENGTH,
        "files": {
            "imageEncoder": file_entry(image_zip),
            "textEncoder": file_entry(text_zip),
            "tokenizer": file_entry(tokenizer_zip),
        },
    }
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))

    swift_path = out_dir / "manifest.swift"
    swift_path.write_text(swift_manifest_literal(manifest))
    print(f"OK. Artifacts in {out_dir}/")
    print(f"Pins for SearchIndexConfig.swift in {swift_path} — paste over the existing `static let manifest`.")


if __name__ == "__main__":
    main()
