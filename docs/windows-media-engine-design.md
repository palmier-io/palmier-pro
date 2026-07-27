# Palmier Pro — Windows media engine: design

Status: **design, not implementation.** Grounded in a complete inventory of the
macOS-side rendering, compositing, decode, audio, and export surfaces (see
"Inventory sources" at the end). This is the largest single sub-project of the
Windows port (~40% of total effort). The goal of this document is to fix the
architecture before writing code, because the wrong seam here costs months.

Read alongside `docs/windows-port-proposal.md` for the broader port context and
`Sources/PalmierPro/Compositing/FrameRenderer.swift` for the contract this all
hinges on.

## The one thing that must be true

> **`PalmierCore` (the portable editor data model) must drive both renderers
> through the same planner, unchanged.**

If we get this right, every timeline edit, every effect, every keyframe, every
text clip renders identically on macOS and Windows — driven by the same
`Timeline` → `CompositorInstruction` → pixels pipeline. The macOS renderer
stays CoreImage/Metal; the Windows renderer is Direct3D/Direct2D. Neither knows
about the other. Everything in `Sources/PalmierPro/Editor/`, `Agent/`,
`Generation/` keeps working because the data model and the planner are shared.

If we get this wrong — by forking the planner, or letting platform types leak
into the contract — we end up with two products that drift, and every shared
edit becomes a portability bug. That is the failure mode to avoid above all
others.

## The seam, precisely

The macOS renderer has exactly one load-bearing entry point. Everything else is
adapter code.

```
Sources/PalmierPro/Compositing/FrameRenderer.swift:8

static func render(
    instruction: CompositorInstruction,
    sourceFrame: (CMPersistentTrackID) -> CVPixelBuffer?,
    compositionTime: CMTime,
    into output: CVPixelBuffer,
    context: CIContext
)
```

Inputs:
- **`CompositorInstruction`** — `{ timeRange, layers: [LayerPlan], renderSize, fps }`,
  produced by the planner from a PalmierCore `Timeline`.
- **`LayerPlan`** — `{ source: track(id) | text | group(children, canvas),
  clip: Clip, natSize, preferredTransform }`. `Clip`, `Transform`, `TextStyle`,
  `Keyframe` are already in `PalmierCore`.
- **`sourceFrame: (TrackID) -> CVPixelBuffer?`** — the **decoder callback**.
  AVFoundation fills it on macOS; Media Foundation fills it on Windows. This is
  the only thing that ties the compositor to a specific decode stack.
- Output: writes BGRA pixels into a caller-provided buffer.

Pipeline per layer (`FrameRenderer.swift:255`):
`crop → effects → edge rounding → transform → opacity`, layers composited
bottom→top with source-over or Photoshop-semantics blend modes.

The planner that produces instructions is also part of the contract:
`CompositionBuilder.compositorInstructions(...)` — turns a `Timeline` + track-id
map into `[CompositorInstruction]`. It is *almost* portable already.

## Two leaks to fix before Windows work starts

The contract above is 95% portable. Two Apple types leak into `LayerPlan` /
`CompositorInstruction` and must be abstracted so `PalmierCore` can drive both
platforms unchanged:

1. **`CMPersistentTrackID`** (an `Int32` typealias) used as the layer track id.
   → Replace with a `TrackID` value type (or `Int`) in `PalmierCore`.
   `LayerPlan.source = .track(TrackID)`. Mechanical.
2. **`CGAffineTransform`** as `LayerPlan.preferredTransform`.
   → Replace with a `Mat3` / row-major 2×3 affine in `PalmierCore`
   (`[a, b, c, d, tx, ty]`). macOS converts to `CGAffineTransform` at the
   CoreImage boundary; Windows converts to `D2D1_MATRIX_3X2_F` /
   `DirectX::XMMATRIX` at the Direct2D boundary.

Both are small, mechanical refactors of two files (`LayerPlan`, the planner),
done on the macOS side first, verified to not regress macOS rendering, then
inherited by Windows for free. This is the first commit of media-engine work.

## Target Windows architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  PalmierCore (portable, shared, already done)                    │
│  Timeline, Clip, Effect, Transform, TextStyle, Keyframe,         │
│  LayerPlan, CompositorInstruction, CompositionBuilder planner    │
└───────────────────────────────┬──────────────────────────────────┘
                                 │ (same call on both platforms)
                ┌────────────────┴────────────────┐
                ▼                                  ▼
  ┌──────────────────────────┐      ┌──────────────────────────────┐
  │ macOS renderer (current) │      │ Windows renderer (new)       │
  │ AVFoundation + CoreImage │      │ Media Foundation + Direct3D  │
  │ + Metal kernels          │      │ 11 + Direct2D + DirectWrite  │
  │ FrameRenderer.render     │      │ WinFrameRenderer.render      │
  └──────────────────────────┘      └──────────────────────────────┘
```

Layer-by-layer mapping (macOS → Windows):

| macOS | Windows | Notes |
|---|---|---|
| `AVAssetReader` / `AVPlayer` decode | **Media Foundation `IMFSourceReader`** for offscreen; **`IMFMediaSession` + custom video sink** for realtime playback | Realtime playback on Windows is the hardest piece — see "Playback" below. |
| `CVPixelBuffer` (BGRA) | **`ID3D11Texture2D`** (BGRA8_UNORM), shared GPU memory | Decode straight into a D3D texture via DXGI keyed-mutex shared surface if possible; else CPU staging copy. |
| `CIContext` + `CIImage` chain | **Direct2D `ID2D1DeviceContext`** + effect graph, OR Win2D-style `CanvasRenderTarget` pipeline | Direct2D has built-in equivalents for most CIFilters (color matrix, gaussian blur, exposure, levels). |
| 12 Metal kernels (`.metal` → `.metallib`) | **HLSL shaders** loaded into a Direct2D `ID2D1Effect` or a custom D3D11 compute/pixel shader | Each of the 12 (LUT tetra, chroma key, clarity, edge rounding, glow, grade curves, grain, highlights/shadows, hue curves, levels, vignette, wheels) is small (~50–150 lines MSL). Port one at a time. |
| `AVVideoCompositing` (`CustomVideoCompositor`) | None — on Windows the renderer is called directly by the playback/export pipeline (no AVFoundation compositor protocol to satisfy) | *Easier* than macOS — fewer layers of indirection. |
| `TextFrameRenderer` (CoreText) | **DirectWrite** (`IDWriteTextFormat` / `IDWriteTextLayout`) rasterized to a D3D texture | Font name → DirectWrite font collection mapping. Hex color → `D2D1_COLOR_F`. The `TextStyle` data model is already portable. |
| `AVAssetExportSession` (SDR) | **Media Foundation `IMFTranscodeSinkWriter`** or an `IMFSinkWriter` + `IMFSourceReader` pump | Codec matrix: H.264/H.265 → MF transform; ProRes needs a third-party or custom MFT. |
| `AVAssetWriter` (HDR pump) | Same `IMFSinkWriter` path with HEVC Main10 + HDR10 metadata | Color-space conversion (709→HLG/PQ) via a D3D11 shader pass, not CPU. |
| Accelerate / vDSP (metering, waveform, envelopes, correlation) | **DirectXMath** + a small DSP module, or `AudioDSP` from the Windows SDK | Pure SIMD math; straightforward port. |
| CoreML / MLX (denoise, beats, VAD, speaker ID) | **ONNX Runtime** (+ optional DirectML EP) running converted models, OR drop the feature on Windows v1 | See "ML paths" below — these are the only genuinely-optional pieces. |

## The attack order (smallest reversible slice first)

1. **Fix the two contract leaks** (`TrackID`, affine matrix) on the macOS side.
   Pure refactor, verified by macOS rendering not regressing. *No Windows code yet.*
2. **Move `LayerPlan` + `CompositorInstruction` + the planner into `PalmierCore`.**
   Same portable-extraction pattern as the 20 commits already landed.
3. **Define the Windows renderer protocol** in `PalmierCore`:
   ```swift
   protocol FrameRendering {
       func render(
           instruction: CompositorInstruction,
           sourceFrame: (TrackID) -> PlatformPixelBuffer?,
           compositionTime: FrameTime,
           into output: PlatformPixelBuffer
       )
   }
   ```
   with platform-specific `PlatformPixelBuffer` (`CVPixelBuffer` on macOS,
   `ID3D11Texture2D*` wrapper on Windows). This is the *only* protocol the two
   renderers share.
4. **Media Foundation decode spike**: stand up `IMFSourceReader` for one test
   asset, decode one frame into a D3D11 texture, prove the callback shape works.
   No compositing yet. *This is where you find out how painful MF really is.*
5. **`WinFrameRenderer` minimal**: composite two static textures bottom→top into
   one output texture. No effects, no transforms. Proves the Direct2D/D3D11
   output path and the BGRA blit.
6. **Add the layer pipeline**: crop → transform → opacity. Skip effects/edge
   rounding/text initially. At this point a Windows build can render a basic
   timeline (cuts only) — the first vertical slice that produces real frames.
7. **Port the 12 HLSL kernels one at a time**, behind the `EffectRegistry`
   shape. LUT tetra and chroma key first (most-used), grain/vignette last.
8. **DirectWrite text layers**.
9. **Export** via `IMFSinkWriter` — reuses the renderer end-to-end.
10. **Realtime playback** — the last and hardest piece (see below).

Each step compiles and runs on Windows before the next begins. Each step is one
or a few commits. The macOS renderer is untouched throughout.

## Playback is the hardest piece — call it out honestly

macOS playback leans entirely on `AVPlayer` + `AVPlayerItem`: AVFoundation
handles decode scheduling, clock, audio sync, and display; Palmier only owns
composition of decoded frames via `CustomVideoCompositing`.

Windows has no `AVPlayer` equivalent. The options, hardest-first:

- **Custom Media Foundation topology + EVR custom presenter**: full control,
  months of work, you own the clock and the audio/video sync. The "correct"
  answer; the expensive one.
- **MF basic playback object (`IMFMediaSession`)** with a custom video sink that
  routes frames through `WinFrameRenderer`: less custom clock work, but the
  custom sink is still substantial and you fight MF's pipeline.
- **Pragmatic v1**: don't do true realtime at all initially — drive a frame-pull
  loop on a high-resolution timer (`QueryPerformanceCounter`), render each frame
  through `WinFrameRenderer`, blit to a swap chain. Audio plays via a separate
  MF pipeline loosely synced. This is "scrubby playback" — good enough to prove
  the editor works on Windows, not good enough to ship. Acceptable for a v1 that
  exists; not acceptable as a final product.

The honest recommendation: **target the pragmatic v1 for the first end-to-end
Windows build**, and treat realtime A/V-synced playback as a dedicated follow-on
sub-project. Trying to ship realtime playback first is how media-engine ports
die.

## ML paths (denoise / beats / VAD / speaker ID) — defer or replace

Four features use bundled CoreML/MLX models that have no Windows Swift
equivalent:

- `AudioEnhancer` (speech enhancement)
- `BeatDetector` (beat detection)
- `VoiceActivity` (VAD)
- `SpeakerIdentity` (speaker clustering)

Three honest options, none free:

1. **Defer on Windows v1.** Ship the editor without them. They're
   quality-of-life features, not core editing. Lowest risk.
2. **Re-author with ONNX Runtime + DirectML.** Convert the bundled models to
   ONNX, run via `Microsoft.ML.OnnxRuntime` (+ DirectML EP for GPU). The model
   *data* exists; the inference runtime is the swap. Real but bounded work per
   feature.
3. **Replace the models.** Pick Windows-friendly equivalents (e.g. a different
   VAD). Loses parity.

Recommendation: **option 1 for v1, option 2 as each feature is requested.** Do
not block the editor on ML.

## Color management — decide once, apply everywhere

macOS tags `CVPixelBuffer`s with `CMFormatDescription` color attachments and
uses `NSNull()` colorSpace at the `CIContext` boundaries to move color
management *into* the effect chain. Windows has no automatic color attachment
tracking; we must:

- Decide the working color space once (recommend **linear Rec.709, alpha
  premultiplied, BGRA8** for v1 — matches macOS's `kCVPixelFormatType_32BGRA`).
- Convert source media to working space on decode (in the MF SourceReader
  output transform or a D3D shader pass), not in the compositor.
- Convert working → output on encode (in the MF SinkWriter input transform or a
  shader pass), with HDR10 metadata for the HEVC Main10 path.

Get this wrong and frames render, but the colors drift. It's the kind of bug
that's invisible until someone compares a macOS and Windows export side by side,
and then it's everywhere. **Spec it before writing the renderer.**

## Risks, ranked

1. **Realtime A/V-synced playback** (see above) — months. Mitigation: pragmatic
   v1 first.
2. **Direct2D effect parity with the 12 Metal kernels** — each kernel is small,
   but color/exposure/levels parity must be bit-close or exports don't match.
   Mitigation: port one at a time, A/B against macOS renders for each.
3. **MF decode into GPU texture without a CPU copy** — the keyed-mutex shared
   surface path is fast but finicky; falling back to CPU staging copies works
   but is slower. Mitigation: measure before optimizing; v1 can be CPU-copy.
4. **ProRes encode on Windows** — MF's built-in MFTs cover H.264/H.265/HEVC;
   ProRes needs a third-party or custom MFT. Mitigation: v1 ships H.264/H.265/
   HEVC only; ProRes is a follow-on.
5. **Color drift** (see above). Mitigation: spec the working space; A/B exports.
6. **Toolchain friction** — Swift-on-Windows linking against D3D/D2D/DWrite/
   MF via `swift-tools-support-core` `systemLibrary` targets is workable but
   has rough edges. Mitigation: proved native Swift compiles+links already
   (PalmierCore, 26s build); D3D binding is the next spike.

## What I will not commit to in writing before verifying

- A release date. The pragmatic-v1 slice is bounded; full parity is not.
- "Bit-identical to macOS." Frame-close, yes; pixel-identical, no — different
  GPU pipelines, different resampling. We aim for perceptually identical.
- ProRes/HDR/scope-accurate color in v1.

## Inventory sources (grounding)

This design is based on a complete read of:

- `Sources/PalmierPro/Compositing/` (FrameRenderer, CompositorInstruction,
  CustomVideoCompositor, EffectRegistry, LUTLoader, TextFrameRenderer,
  ColorScopes, Kernels/CIKernelLoader, the 12 `Metal/*.metal`)
- `Sources/PalmierPro/Preview/` (VideoEngine, CompositionBuilder,
  FrameCaptureRenderer, ImageVideoGenerator, AlphaVideoNormalizer, …)
- `Sources/PalmierPro/Audio/` (AudioTrackReader, ScrubAudioEngine, AudioMeter,
  WaveformExtractor, AudioEnvelope, AudioSyncCorrelator, AudioEnhancer,
  BeatDetector, VoiceActivity, SpeakerIdentity)
- `Sources/PalmierPro/Export/` (ExportService, HDRVideoExporter, ExportOptions)

The single load-bearing function is `FrameRenderer.render` at
`Sources/PalmierPro/Compositing/FrameRenderer.swift:8`.
