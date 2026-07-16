# Color scopes contract — v1 (E6)

Normative spec for Stage E's color-scopes milestone — the plan's "Color scopes: GPU compute
(downsample + groupshared histogram, `InterlockedAdd`), read back only the small result buffer;
runs only while the Inspector color panel is visible." **This document defines the contract
only** — the `PE_ColorScopesResult`/`PE_TimelineComputeColorScopes` declarations in
`native/include/palmier_engine.h` (doc-commented, no `.cpp`) and the `ColorScopesResult` C# record
in `PalmierPro.Rendering` are the two normative surfaces this document specifies. No downsample/
histogram `.hlsl`, no `GpuCompositor.cpp` changes, no `NativeMethods.cs`/`IVideoEngine.cs`/
ViewModel wiring ship with it — see §8 for exactly which future agent owns each of those, mirroring
`docs/audio-playback-v1.md`'s own contract-first split.

## 1. Scope — which Mac mechanism this ports

The Mac has **two unrelated color-measurement mechanisms** that share the word "scopes." This
contract ports exactly one of them.

- **In scope: the Inspector's live histogram views.** `Preview/VideoEngine.swift`'s
  `histogramYRGB(frame:count:)` (luma + per-channel RGB, 256 bins each) and `hueHistogram(frame:count:)`
  (saturation-weighted hue, 96 bins) — consumed by `Inspector/Components/Adjust/CurveEditorView.swift`
  (behind the Curves editor) and `Inspector/Components/Adjust/HueCurveEditorView.swift` (behind the
  Hue Curves editor), both under the Inspector's **Adjust** tab (`InspectorView.ClipTab.effects`,
  `InspectorView.swift:11`; section chrome in `Inspector/Tabs/AdjustTab.swift:114-122`). This is
  "the Inspector color panel" the plan's E6 line refers to — these two views are the only
  Mac UI that computes a scope from the live composited frame on a timer/change-driven cadence.
- **Out of scope, explicitly: `Compositing/ColorScopes.swift`'s `Scopes` struct** (`lumaMean`,
  percentile black/white, per-zone RGB, warm/cool bias, a *different* 12-bin hue histogram, etc.)
  and its only caller, `Agent/Tools/ToolExecutor+Color.swift`'s `inspect_color` tool. This is
  Agent-chat tooling — the plan's "Explicitly out of scope" section defers "Agent chat, MCP
  server, generation panel" to Phase 2 in full. **Do not build `Scopes`/`inspect_color`'s shape
  against this contract** — it has a different bin count (12, not 96), different weighting
  (saturation-thresholded at 0.15, not continuously weighted), and different consumers (an LLM
  tool result, not a live view). A Phase 2 agent porting the Agent tools gets its own contract.

## 2. Result shape — bin counts and normalization, verified against the Mac

Two histogram families, matching `VideoEngine.swift` exactly:

### 2.1 Luma + RGB — 256 bins each (`CurveEditorView`)

`VideoEngine.histogram(from:count:)` (`VideoEngine.swift:286-322`) downsamples the current
composited frame to fit `AVAssetImageGenerator.maximumSize = CGSize(width: 320, height: 180)`
(`VideoEngine.swift:280,336` — aspect-preserving shrink-to-fit, same cap for both histogram
families), then runs Core Image's `CIAreaHistogram` (`inputScale: 1.0, inputCount: 256`) once on
R/G/B directly and once on a luma plane computed with **BT.709 coefficients**
(`CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)`, `VideoEngine.swift:305`) — **not** the
0.3/0.59/0.11 PDF luminosity weight `Common.hlsl`'s `Lum()` already uses for blend modes
(`Common.hlsl:101`). These are two different constants for two different purposes; a GPU
implementation must not reach for `Lum()` here.

Normalization (`VideoEngine.swift:313-320`) — **verbatim, this is the one easiest detail to get
wrong**:

```swift
var maxV: Float = 0
for i in 0..<count {
    y[i] = lumaRaw[i * 4]
    r[i] = rgbRaw[i * 4]; g[i] = rgbRaw[i * 4 + 1]; b[i] = rgbRaw[i * 4 + 2]
    maxV = max(maxV, max(y[i], max(r[i], max(g[i], b[i]))))
}
if maxV > 0 { for i in 0..<count { y[i] /= maxV; r[i] /= maxV; g[i] /= maxV; b[i] /= maxV } }
```

`maxV` is the **single maximum raw bin count across all four histograms jointly** — not a
per-channel max. All four arrays divide by that one scalar. This is what keeps the four overlaid
silhouettes in `CurveEditorView`'s `Canvas` (lines 42-50: luma behind, RGB additively on top,
`.plusLighter` blend) proportionate to each other; per-channel-normalizing would flatten every
channel's peak to 1.0 and destroy that relationship.

`CIAreaHistogram`'s exact bin-boundary rule is undocumented by Apple (no published
value→bin-index formula). This contract specifies the practical, standard one —
`bin = clamp(floor(value × 256), 0, 255)` — and accepts it as a **not-bit-exact, functionally
equivalent** platform difference, the same class of accepted divergence already established for
`Blur.hlsl`'s Gaussian sigma/radius relationship (`Blur.hlsl:1-6`) and the plan's own golden-frame
tolerance language ("SSIM/perceptual tolerance with enumerated expected-mismatch sources").

### 2.2 Hue — 96 bins, saturation-weighted (`HueCurveEditorView`)

`VideoEngine.hueHistogram(from:count:)` (`VideoEngine.swift:342-367`), same 320×180 downsample.
Per pixel:

```swift
let mx = max(r, max(g, b)), mn = min(r, min(g, b)), d = mx - mn
guard d > 1e-4, mx > 1e-4 else { continue }                    // near-achromatic pixels don't vote
var hue: Float = mx == r ? (g - b) / d : (mx == g ? (b - r) / d + 2 : (r - g) / d + 4)
hue = (hue / 6).truncatingRemainder(dividingBy: 1); if hue < 0 { hue += 1 }
bins[min(count - 1, Int(hue * Float(count)))] += d / mx        // weight = saturation, not a +1 vote
```

Then, distinct from §2.1's normalization: find `maxV` across the 96 bins, and **sqrt-compress**
after normalizing (`VideoEngine.swift:364-365`: `bins[j] = (bins[j] / maxV).squareRoot()`) — so
small humps stay visible against a dominant peak. Do not skip the sqrt; it is not merely a
cosmetic curve applied later in the view, it is baked into what the engine returns on the Mac and
must be baked in natively too, since `HueCurveEditorView` draws the returned values directly
(`HueCurveEditorView.swift:38-44`).

### 2.3 What "the current composited frame" means here

Both Mac functions run against `player.currentItem` at the requested frame — i.e. the **full
timeline composite** (every visible track, every clip's effect chain, at that playhead position),
not an isolated render of just the selected clip. `color.curves`/`color.hueCurves` are per-clip
effects, but the histogram drawn behind their editors reflects what's on screen, matching what the
user is actually grading against. The Windows source is therefore the same accumulator
`GpuCompositor::Compose` already produces for ordinary preview/present — see §5.

## 3. GPU compute design (non-normative — implementation guidance, not part of the ABI)

This section is guidance for whichever future agent implements the `.hlsl`/`GpuCompositor.cpp`
side (§8); it is not itself a contract obligation beyond producing the numeric results §2 defines.

- **Downsample pass.** `GpuCompositor`'s final accumulator (`accum_[current]`,
  `R16G16B16A16_FLOAT`, gamma-encoded, premultiplied) is always **opaque** at the end of a compose
  — cleared to `{0,0,0,1}` and every per-track composite is `over`, never introducing transparency
  (`GpuCompositor.cpp:1072-1073`, "opaque black, matching Compositor.cpp"). Premultiplied-by-1.0
  alpha equals straight color, so **no unpremultiply divide is needed** reading this texture for
  scopes — a genuine simplification versus a general-purpose readback path, worth stating
  explicitly rather than silently assuming. A compute shader box-filters this down to a grid sized
  by the same aspect-fit-shrink rule as `AVAssetImageGenerator.maximumSize` (§2.1): `scale =
  min(1, min(320/width, 180/height))`, `gridW = round(width×scale)`, `gridH = round(height×scale)`
  — writing to an `RWTexture2D<float4>` scratch texture. Reuses the existing `GetOrCompileCS`
  cache and `numthreads(8,8,1)` / `(dim+7)/8` dispatch convention already established by
  `Blur.hlsl`'s `BlurHorizontalCS`/`BlurVerticalCS` (`GpuCompositor.cpp:469-511`).
- **One combined histogram pass**, not two. Both histogram families (§2.1, §2.2) are pure
  per-pixel classifications of the *same* downsampled grid — one dispatch can compute Y/R/G/B bin
  counts and the hue-weighted sum together, halving the downsample-texture reads versus mirroring
  the Mac's two independent `AVAssetImageGenerator`/`CIAreaHistogram` call chains. One thread per
  downsampled texel: `numthreads(8,8,1)`, groups = `((gridW+7)/8, (gridH+7)/8, 1)`.
- **`groupshared` local accumulation, `InterlockedAdd` to merge.** Per the plan's own naming. Y/R/G/B
  are plain pixel *counts* — `groupshared uint localY[256]`, `localR[256]`, `localG[256]`,
  `localB[256]` (4 KB total, well under the 32 KB SM5 `groupshared` cap), each thread does
  `InterlockedAdd(localY[binIndex], 1)` etc., then after `GroupMemoryBarrierWithGroupSync()` one
  thread per group flushes each non-zero local bin into a device-memory
  `RWStructuredBuffer<uint>` with `InterlockedAdd` — the standard two-level histogram pattern that
  avoids every thread contending on the same global atomic.
- **Hue needs fixed-point, not float, atomics.** SM5 `InterlockedAdd` is integer-only — there is
  no float-UAV atomic to accumulate a saturation-weighted *sum* directly. Scale the per-pixel
  weight (`d/mx ∈ (0,1]`) by a fixed-point factor before the atomic: **`kHueFixedPointScale =
  32768` (2¹⁵)**. Worst case (every one of the ≤320×180 = 57,600 downsampled pixels lands in one
  bin at weight ≈1) sums to `57,600 × 32,768 ≈ 1.89×10⁹`, comfortably under `UINT32_MAX`
  (`≈4.29×10⁹`, ~2.3× headroom) with `1/32768 ≈ 3×10⁻⁵` resolution — plenty for a sqrt-compressed
  display curve. Native divides back by 32768 after readback, before finding `maxV` and applying
  §2.2's sqrt.
- **One packed buffer, one readback — matches the plan's singular "the small result buffer."**
  `RWStructuredBuffer<uint>` of length `4×256 + 96 = 1120` (4,480 bytes): offsets `[0,256)` = Y,
  `[256,512)` = R, `[512,768)` = G, `[768,1024)` = B, `[1024,1120)` = hue (fixed-point). One
  staging-buffer `Map(D3D11_MAP_READ)` — the same `CopyResource`→`Map` shape `ReadbackToBgra8`
  already uses (`GpuCompositor.cpp:989,1012-1015`), just a ~4.5 KB buffer instead of a
  canvas-sized texture, which is the entire point of downsampling *before* histogramming rather
  than after.
- **Implementation freedom, not a requirement:** reusing an already-composited `accum_` texture
  when the requested frame matches the timeline's last-presented frame (instead of forcing a fresh
  full recompose) is a valid optimization. It must not change §2's numeric output — the contract
  is defined on "the composited frame at `frame`," not on any particular compose call being fresh.

## 4. Update cadence and visibility gating semantics

**No native enable/disable flag.** Unlike the render thread's continuous playback present loop
(`docs/audio-playback-v1.md` §3.5), color scopes are **pull-based**: native computes and returns a
result only when `PE_TimelineComputeColorScopes` (§6) is called, and is otherwise fully idle. "Runs
only while the Inspector color panel is visible" is satisfied entirely by **caller discipline** —
mirroring the Mac exactly, where `histogramYRGB`/`hueHistogram` are never invoked from anywhere
except these two views' own lifecycle hooks. There is no engine-side concept of "the panel is
visible"; the engine only ever knows "a caller just asked."

The future C# ViewModel/service wrapping this call (§8) **must** replicate the Mac's exact trigger
set and guards — both `CurveEditorView.swift:97-100` and `HueCurveEditorView.swift:89-92` share
this identically:

- Refresh on **first appearance** of the Adjust tab's Curves/Hue Curves sections, on
  **`timelineRenderRevision` changing** (any edit that could change what's on screen), on
  **`activeFrame` changing** (playhead moved), and when **`isPlaying` transitions to `false`**
  (scrub/playback settle).
- **Never while `isPlaying` is `true`.** `CurveEditorView.swift:105` / `HueCurveEditorView.swift:97`:
  `guard editor.videoEngine != nil, !editor.isPlaying else { return }`. Scopes are a settle-time
  readout, not a live-playback overlay — this is a **must**, not a suggestion: wiring this call to
  fire every playback frame would defeat the entire point of downsampling-before-histogramming
  (§3's last bullet) by adding a GPU readback stall to the playback present loop, which
  `docs/audio-playback-v1.md` §3.5 explicitly keeps present-only/never-blocking.
- **One request in flight at a time, coalesced.** Mac's `histInFlight`/`histDirty` pattern
  (`CurveEditorView.swift:104-116`, `HueCurveEditorView.swift:96-106`): if a refresh is already
  running when another trigger fires, set a dirty flag instead of issuing a second call; when the
  in-flight call completes, if dirty, immediately re-issue once (not once per missed trigger). Port
  this coalescing verbatim — it is what keeps rapid edits (e.g. a live slider drag on an unrelated
  param that still bumps `timelineRenderRevision`) from queuing up redundant GPU work.
- **Tab-visibility is the caller's job, not just view-lifecycle's.** On the Mac, SwiftUI only
  instantiates `CurveEditorView`/`HueCurveEditorView` (and so only fires their `.onAppear`) when
  `InspectorView.ClipTab.effects` is the selected tab — the view literally doesn't exist otherwise.
  Whatever WinUI mechanism M5 uses to switch Inspector tabs must have the same property (the
  histogram-refresh code path must not run, or must not even be reachable, while a different
  Inspector tab is selected) — a `Visibility`-toggled-but-still-loaded XAML tree does **not**
  satisfy this by itself unless the refresh subscription is also torn down/suspended on tab switch.
- **One call now serves both histogram families (§3's "one combined pass").** The recommended C#
  shape is a single cached `ColorScopesResult` (§7) shared by both editor views' view-models, with
  one in-flight/dirty pair, not two independent Mac-style fetches — see §8 for why this is a
  genuine efficiency win over a literal 1:1 port and not just a simplification.

## 5. Compose source and threading

`PE_TimelineComputeColorScopes` composes `frame` through the **same** `GpuCompositor` pipeline
already used by `PE_TimelineRenderFrameToFile` — same clip decode, effect chain, per-track blend —
diverging only at the final stage (§3's downsample+histogram compute instead of the BGRA8 CPU
readback `ReadbackToBgra8` performs). Threading contract mirrors
`PE_TimelineRenderFrameToFile` (`palmier_engine.h:244-247`): **synchronous on the calling thread,
bypassing the render thread's seek mailbox entirely** — deterministic, unaffected by any
concurrent `PE_TimelineSeek` on the same handle, serialized against every other D3D11 call on this
session through the existing shared immediate-context mutex (`palmier_engine.h:148-162`). It is
*not* a UI-thread-only call the way `PE_AttachSwapChain`/`PE_TimelineAttachSwapChain` are — like
`PE_TimelineRenderFrameToFile`, it has no swap-chain/window-handle dependency, so the future C#
wrapper is expected to invoke it off the UI thread (`Task.Run`, matching how
`VideoEngine.histogramYRGB`/`hueHistogram` are already `async` on the Mac side, awaited from a
background `Task` in `CurveEditorView`/`HueCurveEditorView` rather than the main actor blocking).

No new error codes. Compose failure (bad/missing media, decode failure, cancellation — none of
which apply here since this call takes no cancel flag, mirroring `PE_TimelineRenderFrameToFile`)
surfaces through the same `PE_Status` values `PE_TimelineRenderFrameToFile` already uses.
`PE_ERROR_INVALID_ARGUMENT` for a null `outResult`; `PE_ERROR_INVALID_HANDLE` for an unknown/closed
timeline.

## 6. ABI additions

Declared in `native/include/palmier_engine.h` (see that file for the literal, doc-commented
declarations — reproduced here for reference; the header is the source of truth if the two ever
drift):

```c
enum PE_ColorScopesConstants : int32_t
{
    PE_COLOR_SCOPES_RGB_BINS = 256,
    PE_COLOR_SCOPES_HUE_BINS = 96,
    PE_COLOR_SCOPES_MAX_GRID_WIDTH = 320,
    PE_COLOR_SCOPES_MAX_GRID_HEIGHT = 180,
};

struct PE_ColorScopesResult
{
    int64_t frame;
    float yHistogram[PE_COLOR_SCOPES_RGB_BINS];
    float rHistogram[PE_COLOR_SCOPES_RGB_BINS];
    float gHistogram[PE_COLOR_SCOPES_RGB_BINS];
    float bHistogram[PE_COLOR_SCOPES_RGB_BINS];
    float hueHistogram[PE_COLOR_SCOPES_HUE_BINS];
};

PALMIER_API int32_t PE_TimelineComputeColorScopes(PE_TimelineHandle timeline, int64_t frame, PE_ColorScopesResult* outResult);
```

**Why one struct with five fixed arrays, not a buffer+cap pair like `PE_ExtractPeakEnvelope`:**
every bin count here is a fixed, versioned constant (§2), not caller-variable — `PE_ExtractPeakEnvelope`
takes `peaksPerSecond`/`cap` because callers legitimately want different peak densities for
different UI contexts (timeline filmstrip vs. a zoomed waveform). Nothing here varies per call
except `frame`. A fixed out-struct matches the existing `PE_GetMediaInfo`/`PE_MediaInfo` shape,
not the peak-envelope shape, because the *reason* for buffer+cap (caller-chosen size) doesn't
apply.

**Why `frame` is echoed back in the result, not just implied by the call's own `frame` argument:**
matches `PE_TimelineGetClockFrame`'s general pattern of a synchronous, self-describing result — a
future async wrapper (§8) can validate a returned result against the frame it originally requested
without needing to separately track call/response pairing itself.

**Why this isn't folded into the existing `PE_TimelineRenderFrameToFile`/`ComposeResult` path:**
that call's contract is "produce a displayable BGRA8 image," a fundamentally different output
shape and consumer (golden-fixture PNG encode) than "produce five small histograms." Overloading
one ABI entry point to conditionally return two unrelated shapes would need an output-selector
parameter for no benefit — two entry points sharing internal compose plumbing (§3, §5) is the
established pattern already (`PE_TimelineRenderFrameToFile` and the render thread's own
`ComposeFrame` already share `GpuCompositor::Compose` this same way).

## 7. C# result-struct stub

Declared in `PalmierPro.Rendering/ColorScopesResult.cs` — see that file for the literal code
(reproduced here for reference):

```csharp
public sealed record ColorScopesResult(
    long Frame,
    IReadOnlyList<float> YHistogram,
    IReadOnlyList<float> RHistogram,
    IReadOnlyList<float> GHistogram,
    IReadOnlyList<float> BHistogram,
    IReadOnlyList<float> HueHistogram)
{
    public const int RgbBinCount = 256;
    public const int HueBinCount = 96;
}
```

This is a **pure data-shape stub** — no `[LibraryImport]`/`NativeMethods.cs` entry, no
`PE_ColorScopesResult`-mirroring `[StructLayout]` marshaling struct, no `FromNative` converter, and
no `IVideoEngine` member ship with it, matching `docs/audio-playback-v1.md`'s own "no P/Invoke
wiring ships with the contract" precedent. `ColorScopesResult` exists now so a future Inspector
ViewModel (M5) can be written and unit-tested against a stable public shape before the native call
lands — same reason `PlayheadChangedEventArgs`/`IsPlayingChanged` were declared on `IVideoEngine`
in Stage B, unraised, ahead of E4.5 actually firing them.

`IReadOnlyList<float>` (not `float[]`) so the eventual `FromNative` conversion can hand out either
a freshly-copied array or a `ReadOnlyMemory<float>`-backed view without changing the public
signature — mirrors `DecodedFrame`'s existing `ReadOnlyMemory<byte>` convention in `MediaInfo.cs`
for engine-owned buffers, while leaving the choice of "copy vs. alias" to whoever writes the real
marshaling (a `PE_ColorScopesResult`'s arrays are embedded inline in a struct returned by value
across P/Invoke, not an engine-owned buffer valid-until-next-call like `PE_FrameBuffer`, so copying
out is actually the only option — `IReadOnlyList<float>` is still the right public type regardless,
since callers should not care).

## 8. Agent split — who implements what

This contract intentionally separates concerns so the following can proceed in parallel once this
document and the ABI header land, mirroring `docs/audio-playback-v1.md` §9's split:

| Slice | Owns | Key files |
|---|---|---|
| **shaders** | `Downsample.hlsl` (box-filter compute, §3) and `ColorScopesHistogram.hlsl` (combined Y/R/G/B/hue groupshared-histogram compute, §3) | new `native/shaders/Downsample.hlsl`, `native/shaders/ColorScopesHistogram.hlsl` |
| **compositor** | `GpuCompositor::ComputeColorScopes` (a `Compose`-sibling method reusing clip-decode/effect-chain/composite internals, diverging at the final stage per §3/§5), the packed-buffer readback + fixed-point unpack + §2's two normalization schemes, `PE_TimelineComputeColorScopes` implementation | `native/GpuCompositor.h/.cpp`, `native/TimelineSession.h/.cpp`, `native/PalmierEngine.cpp` |
| **abi-wiring** | `NativeMethods.cs`'s `PE_ColorScopesResult` marshaling struct + `PE_TimelineComputeColorScopes` `[LibraryImport]`, `ColorScopesResult.FromNative`, the `IVideoEngine` member (e.g. `Task<ColorScopesResult?> GetColorScopesAsync(string timelineId, int frame, CancellationToken ct = default)`) stubbed with `NotSupportedException` in `VideoEngine.cs` until wired | `NativeMethods.cs`, `ColorScopesResult.cs`, `IVideoEngine.cs`, `VideoEngine.cs` |
| **inspector-vm** | The M5 ViewModel(s) behind `CurveEditorView`/`HueCurveEditorView`'s WinUI ports: §4's trigger set, the `histInFlight`/`histDirty` coalescing port, the single-shared-`ColorScopesResult` consumption by both editors (§4's last bullet), and ensuring the refresh path is unreachable while the Adjust tab isn't selected | new Inspector ViewModel files under `PalmierPro.App/ViewModels/Inspector/` |

**Dependency ordering:** shaders and abi-wiring have no dependency on each other and can proceed
in parallel once this document lands. compositor depends on shaders (needs the compiled passes to
call) but its C++ structure (readback/unpack/normalize) can be written and unit-tested against a
stub/known input buffer before the real shaders exist. inspector-vm depends on abi-wiring (needs
`IVideoEngine.GetColorScopesAsync` to exist, even mid-`NotSupportedException`, to compile against)
but not on compositor/shaders being real — exactly the same "build the ceiling before the floor"
sequencing `docs/audio-playback-v1.md` §9 already established for E4.5.

## 9. AppTheme — no new tokens

Checked against `Sources/PalmierPro/UI/AppTheme.swift`'s `Curve`/`Wheels`/`Opacity` enums: every
color and dimension `CurveEditorView`/`HueCurveEditorView` draw with — `AppTheme.Curve.lumaColor`/
`.redColor`/`.greenColor`/`.blueColor`/`.editorHeight`/`.pointDiameter`, `AppTheme.Opacity.medium`/
`.muted`/`.prominent`, `AppTheme.Border.subtleColor`, `AppTheme.BorderWidth.hairline`/`.medium` —
was already ported verbatim into `PalmierPro.Core.Theme.AppThemeTokens` (`Curve`/`Wheels` classes,
`AppThemeTokens.cs:149-169`) and `Theme.xaml` (`AppCurve*`/`AppWheels*` resources,
`Theme.xaml:100-119`) at Stage 0, alongside the rest of the 29-category verbatim port. This
contract's own deliverable (doc + ABI header + a data-only C# record) introduces no new drawing
surface, so **no `AppThemeTokens.cs`/`Theme.xaml`/`ThemeParityTests.cs` changes are needed here** —
the future `inspector-vm` slice (§8) should reach for the existing `Curve`/`Wheels`/`Opacity`
tokens when it builds the actual WinUI scope views, and add a token there first (per
`platforms/windows/AGENTS.md`'s Design System rule) only if it finds a value the Mac's `AdjustTab`/
`CurveEditorView`/`HueCurveEditorView` genuinely doesn't already have a token for.
