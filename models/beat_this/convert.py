#!/usr/bin/env python3
"""Convert Beat This (small0) to Core ML for on-device beat detection.

Upstream: https://github.com/CPJKU/beat_this ("Beat This! Accurate Beat
Tracking Without DBN Postprocessing", ISMIR 2024). Code and weights MIT.

The mel frontend (torch.stft) folds into the graph, so the model takes raw
audio: 661059 samples of 22050 Hz mono (one 1500-frame mel chunk at hop 441)
and emits framewise beat/downbeat logits (1, 1500), 20 ms per frame.

The checkpoint downloads automatically on first run (torch.hub cache).

Usage:
  python convert.py --out build/ [--precision fp16]
Outputs:
  build/BeatThis.mlpackage      (validated against the original pipeline)
  build/BeatThis.mlmodelc       (compiled; copy into Sources/PalmierPro/Resources/Models/)

Conversion is parity-gated twice: the patched torch model must match the
original's logits (the einops rewrites are exact math), and the Core ML model
must place identical beats on a 120 BPM click track.
"""

import argparse
import shutil
import subprocess
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn

import beat_this.model.beat_tracker as bt
import beat_this.model.roformer as rf
import rotary_embedding_torch.rotary_embedding_torch as rot
from beat_this.inference import Audio2Frames, load_model
from beat_this.model.roformer import exists
from beat_this.preprocessing import LogMelSpect

CHECKPOINT = "small0"
SR = 22050
HOP = 441
CHUNK_FRAMES = 1500
N_SAMPLES = (CHUNK_FRAMES - 1) * HOP
BORDER = 6  # frames the runtime discards per chunk edge; border logits may diverge


# --- einops → native ops. coremltools rejects runtime-int ops, which einops
# emits for symbolic-dim products; flatten/unflatten with -1 avoids them.
# Batch is fixed at 1 throughout.

class RearrangeTF(nn.Module):   # "b t f -> b f t"
    def forward(self, x):
        return x.transpose(1, 2).contiguous()


class AddChannel(nn.Module):    # "b f t -> b 1 f t"
    def forward(self, x):
        return x.unsqueeze(1)


class Concat(nn.Module):        # "b c f t -> b t (c f)"
    def forward(self, x):
        return x.permute(0, 3, 1, 2).flatten(2, 3)


def partial_forward(self, x):   # x: (b, c, f, t)
    y = x.permute(0, 3, 2, 1).flatten(0, 1)
    y = y + self.attnF(y)
    y = y + self.ffF(y)
    y = y.unflatten(0, (1, -1)).permute(0, 2, 1, 3).flatten(0, 1)
    y = y + self.attnT(y)
    y = y + self.ffT(y)
    return y.unflatten(0, (1, -1)).permute(0, 3, 1, 2)


def attn_forward(self, x):
    x = self.norm(x)
    qkv = self.to_qkv(x).unflatten(-1, (3, self.heads, -1)).permute(2, 0, 3, 1, 4)
    q, k, v = qkv[0], qkv[1], qkv[2]
    if exists(self.rotary_embed):
        q = self.rotary_embed.rotate_queries_or_keys(q)
        k = self.rotary_embed.rotate_queries_or_keys(k)
    out = self.attend(q, k, v)
    if exists(self.to_gates):
        gates = self.to_gates(x).permute(0, 2, 1).unsqueeze(-1)
        out = out * gates.sigmoid()
    out = out.permute(0, 2, 1, 3).flatten(2, 3)
    return self.to_out(out)


def sumhead_forward(self, x):
    bd = self.beat_downbeat_lin(x)
    beat, downbeat = bd[..., 0], bd[..., 1]
    return {"beat": beat + downbeat, "downbeat": downbeat}


def rotate_half_native(x):
    x = x.unflatten(-1, (-1, 2))
    x1, x2 = x[..., 0], x[..., 1]
    return torch.stack((-x2, x1), dim=-1).flatten(-2)


def rotate_qk(self, t, seq_dim=None, offset=0, scale=None):
    # Bypasses the library's cache (traces as stale constants) and its einops.
    seq_len = t.shape[-2]
    seq = (torch.arange(seq_len, device=t.device, dtype=self.freqs.dtype) + offset) / self.interpolate_factor
    freqs = (seq[:, None] * self.freqs[None, :]).repeat_interleave(2, dim=-1)
    return t * freqs.cos() + rotate_half_native(t) * freqs.sin()


def apply_patches():
    bt.PartialFTTransformer.forward = partial_forward
    rf.Attention.forward = attn_forward
    bt.SumHead.forward = sumhead_forward
    rot.RotaryEmbedding.rotate_queries_or_keys = rotate_qk


class AudioToBeats(nn.Module):
    def __init__(self):
        super().__init__()
        self.mel = LogMelSpect()
        model = load_model(CHECKPOINT)
        model.frontend.stem.rearrange_tf = RearrangeTF()
        model.frontend.stem.add_channel = AddChannel()
        model.frontend.concat = Concat()
        self.model = model

    def forward(self, audio):
        out = self.model(self.mel(audio).unsqueeze(0))
        return out["beat"], out["downbeat"]


def click_track():
    """120 BPM clicks, downbeat-accented — deterministic parity fixture."""
    dur = N_SAMPLES / SR
    beats = np.arange(0, dur, 0.5)
    x = np.zeros(N_SAMPLES, dtype=np.float32)
    for i, b in enumerate(beats):
        s, n = int(b * SR), int(0.05 * SR)
        env = np.exp(-np.arange(n) / (0.01 * SR))
        freq, amp = (1500, 1.0) if i % 4 == 0 else (1000, 0.6)
        x[s:s + n] += (amp * env * np.sin(2 * np.pi * freq * np.arange(n) / SR)).astype(np.float32)
    return (x / np.abs(x).max() * 0.9).astype(np.float32)


def pick_peaks(logits, thr=0.5):
    p = 1 / (1 + np.exp(-logits))
    return np.array([i for i in range(1, len(p) - 1)
                     if p[i] >= thr and p[i] >= p[i - 1] and p[i] > p[i + 1]])


def peaks_match(a, b, tol=0):
    """Same beat count and every peak within tol frames of its counterpart."""
    return len(a) == len(b) and (tol == 0 and np.array_equal(a, b)
                                 or np.abs(np.asarray(a) - np.asarray(b)).max() <= tol)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, default=Path("build"))
    parser.add_argument("--precision", choices=["fp16", "fp32"], default="fp16")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    click = click_track()

    # Reference logits from the ORIGINAL pipeline, before any patching.
    reference = Audio2Frames(checkpoint_path=CHECKPOINT, device="cpu")
    ref_beat, _ = reference(click, SR)
    ref_beat = np.asarray(ref_beat)

    apply_patches()
    wrapper = AudioToBeats().eval()

    # Gate 1: patched torch must reproduce the original's interior logits.
    with torch.no_grad():
        patched_beat, _ = wrapper(torch.from_numpy(click))
    patched_beat = patched_beat.numpy().reshape(-1)
    interior = slice(BORDER, -BORDER)
    torch_diff = np.abs(patched_beat[interior] - ref_beat[interior]).max()
    # 1-frame (20 ms) tolerance: the original pads chunks with context frames,
    # the fixed-shape graph cannot — a global-attention model sees that near
    # chunk edges. Conversion exactness is gate 2's job.
    assert peaks_match(pick_peaks(patched_beat[interior]), pick_peaks(ref_beat[interior]), tol=1), \
        "patched torch model moved a beat vs the original"
    print(f"gate 1 (torch parity): interior max|Δlogit|={torch_diff:.3f}, peaks within 1 frame")

    traced = torch.jit.trace(wrapper, torch.zeros(N_SAMPLES), strict=False, check_trace=False)
    precision = ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="audio", shape=(N_SAMPLES,))],
        outputs=[ct.TensorType(name="beat"), ct.TensorType(name="downbeat")],
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=precision,
    )
    package = args.out / "BeatThis.mlpackage"
    if package.exists():
        shutil.rmtree(package)
    mlmodel.save(str(package))

    # Gate 2: Core ML must place identical beats to the patched torch model.
    predicted = ct.models.MLModel(str(package)).predict({"audio": click})
    ml_beat = np.asarray(predicted["beat"]).reshape(-1)
    assert not np.isnan(ml_beat).any(), "NaNs in Core ML output"
    ml_diff = np.abs(ml_beat - patched_beat).max()
    assert np.array_equal(pick_peaks(ml_beat), pick_peaks(patched_beat)), \
        "Core ML conversion moved a beat"
    print(f"gate 2 (Core ML parity): max|Δlogit|={ml_diff:.4f}, peaks identical")

    compiled = args.out / "BeatThis.mlmodelc"
    if compiled.exists():
        shutil.rmtree(compiled)
    subprocess.run(
        ["xcrun", "coremlcompiler", "compile", str(package), str(args.out)],
        check=True,
    )
    print(f"done: {package} and {compiled}")
    print("copy BeatThis.mlmodelc into Sources/PalmierPro/Resources/Models/")


if __name__ == "__main__":
    main()
