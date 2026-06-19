# Color grading (LUT + adjustment layers) & chroma key — design

Date: 2026-06-19
Status: approved (scope + architecture), implementation pending

## Goal

Add two color-pipeline features to Palmier Pro:

1. **Color grading** via Premiere-style **adjustment layers** — UI only (no MCP).
   A `.cube` LUT (with intensity) plus five basic controls: Temperature, Tint,
   Exposure, Contrast, Saturation. An adjustment layer grades the layers **below
   it in z-order**, only for its time span (faithful Premiere model). Panel UI in
   the Premiere "Lumetri" visual identity, **collapsible-sections layout**
   (Basic Correction + Creative/LUT), each section with its own fx enable toggle.

2. **Chroma key (green screen)** — **Ultra Key**, per clip, controllable by the
   MCP agent **and** via UI. Controls: key color (default green; eyedropper in UI,
   RGB over MCP), tolerance, softness/edge smoothing, spill suppression.

Both features share one new piece of infrastructure: a **custom Core Image
`AVVideoCompositing`** that replaces the built-in compositor in the existing
render path.

### Out of scope (v1)

- Keyframing color/key parameters (static per layer/clip for v1).
- LUT formats other than `.cube`.
- Bundled LUT presets (user imports their own).
- Arbitrary eyedropper sampling over MCP (agent passes RGB or relies on green default).

## Why a custom compositor

Today `CompositionBuilder.buildVisuals` produces an `AVVideoComposition` driven by
AVFoundation's **built-in** compositor using `AVVideoCompositionLayerInstruction`
(transform / opacity / crop ramps). Text is composited separately (CATextLayer in
preview, animation tool in export), never as composition tracks.

The built-in compositor cannot:
- give an adjustment layer access to "the composited image of everything below it"; or
- apply a per-clip chroma key (alpha derived from pixel color) with live preview.

`AVVideoComposition(asset:applyingCIFiltersWithHandler:)` only sees the *fully
composited* output frame — it cannot separate "below" from "above" or act per clip.
Therefore a custom `AVVideoCompositing` is required. Because **every** consumer
(`VideoEngine`, `ExportService`, `TimelineRenderer`, `ToolExecutor+InspectTimeline`,
`EditorViewModel+MediaLibrary`) reads the single `AVVideoComposition` from
`CompositionResult`, setting `customVideoCompositorClass` in `buildVisuals` makes
preview and export use it transparently — no consumer changes.

Risk is contained because the geometry math is **reused**: `Clip` and `Track` are
`Sendable`, so the compositor samples `clip.transformAt(frame:)` /
`opacityAt(frame:)` / `cropAt(frame:)` directly and reuses
`CompositionBuilder.affineTransform(for:natSize:renderSize:)`. No keyframe-ramp
emission is needed in the custom path — we sample the model at the exact frame.

## Architecture

### Data model (additive, backward compatible — all new fields optional with defaults)

`Models/Color.swift` (new):
- `struct ColorGrade: Codable, Sendable, Equatable` — `temperature, tint,
  exposure, contrast, saturation: Double` (neutral defaults), `lutRef: String?`
  (filename inside the project package, like `mediaRef`), `lutIntensity: Double`
  (0…1), `basicEnabled: Bool`, `creativeEnabled: Bool`.
- `struct ChromaKey: Codable, Sendable, Equatable` — `enabled: Bool`,
  `keyColor: RGBA` (default green), `tolerance, softness, spill,
  edgeFeather: Double`.

`Models/ClipType.swift`: add `case adjustment`. `isVisual` stays false for
`.adjustment` (it produces no source frame). Add icon + label.

`Models/Timeline.swift`:
- `Clip` gains `var chromaKey: ChromaKey?` and `var colorGrade: ColorGrade?`
  (the latter only meaningful on adjustment clips). Both added to `CodingKeys`
  and the tolerant `init(from:)` as `try?` so old projects decode unchanged.
- An adjustment layer is a `Track(type: .adjustment)` holding `Clip`s with
  `mediaType = .adjustment`, `mediaRef = ""`, and a `colorGrade`. It occupies a
  time span and a z-order position like any clip.

### Render pipeline

`Preview/ColorVideoCompositor.swift` (new) — `final class ColorVideoCompositor:
NSObject, AVVideoCompositing`:
- `sourcePixelBufferAttributes` / `requiredPixelBufferAttributes`: BGRA, Metal-compatible.
- One shared `CIContext` (Metal device).
- `startRequest(_:)`: read the custom instruction, compute `frame = round(time *
  fps)`, build the output buffer from the pool, render via `composite(...)`,
  finish.

`Preview/ColorCompositionInstruction.swift` (new) — `final class
ColorCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol`:
- `timeRange`, `enablePostProcessing = false`, `containsTweening = true`,
  `requiredSourceTrackIDs` (all visual comp track IDs active in range),
  `passthroughTrackID = kCMPersistentTrackID_Invalid`.
- Carries a `Sendable` z-ordered `[Layer]` where `Layer` is either
  `.source(trackID, clips:[Clip], natSize, preferredTransform)` or
  `.adjustment(clips:[Clip])`, plus `renderSize`, `fps`, and a `lutResolver`
  (a `Sendable` map `lutRef -> CIColorCube data`, pre-baked at build time so the
  compositor never touches disk).

Compositing per frame (bottom → top):
1. Start from a transparent/black accumulator (`CIImage`).
2. For a `.source` layer: find the active clip at `frame`; get
   `request.sourceFrame(byTrackID:)`; wrap as `CIImage`; apply `preferredTransform`;
   if `clip.chromaKey?.enabled`, run the Ultra Key kernel; apply crop
   (`clip.cropAt(frame)`); apply `affineTransform(for: clip.transformAt(frame), …)`;
   multiply alpha by `clip.opacityAt(frame)`; source-over onto accumulator.
3. For an `.adjustment` layer active at `frame`: apply the `ColorGrade` chain to
   the **accumulator** (everything below), then continue.
4. Render accumulator → output `CVPixelBuffer`.

`Color/ColorGradePipeline.swift` (new, pure, unit-testable): builds the CIImage
chain — `CITemperatureAndTint` → `CIColorControls` (brightness=exposure,
contrast, saturation) → `CIColorCube`/`CIColorCubeWithColorSpace` (LUT) blended
toward the original by `(1 - lutIntensity)`. Honors `basicEnabled`/`creativeEnabled`.

`Color/CubeLUT.swift` (new, pure, unit-testable): parse Adobe `.cube` (1D/3D,
`LUT_3D_SIZE`, `DOMAIN_MIN/MAX`, comments) → validated `Float` cube data + size
for `CIColorCube`. Throws a typed error on malformed input.

`Color/UltraKey.ci.metal` + `Color/UltraKey.swift` (new): a `CIKernel` (Metal)
that converts the source to alpha by distance from `keyColor` in a chroma space
(YCbCr), with `tolerance`/`softness` shaping the alpha ramp, `edgeFeather`
blurring the matte edge, and `spill` desaturating residual key color toward
luminance. Unit-tested on a synthetic green/subject image.

`Preview/CompositionBuilder.swift` changes:
- In `build`, **skip** creating composition tracks for `.adjustment` clips (they
  have no media). Collect them as instruction layers instead.
- Pre-bake each referenced `.cube` into CIColorCube data once and pass via the
  instruction `lutResolver`.
- In `buildVisuals`, when any adjustment/chroma feature is present, set
  `vcConfig.customVideoCompositorClass = ColorVideoCompositor.self` and build a
  single `ColorCompositionInstruction` (z-ordered layers) instead of the
  `AVVideoCompositionLayerInstruction` array. **Audio path is untouched.**
- When no color/key feature is used anywhere, keep the existing built-in path
  verbatim (zero behavior change / zero regression risk for existing projects).

### LUT import & storage

- UI "Import LUT…" copies the chosen `.cube` into the project package (next to
  media), validates it via `CubeLUT.parse`, and stores the package-relative
  filename in `ColorGrade.lutRef`. Resolution reuses the existing media-ref → URL
  resolver. Portable with the project.

### UI

`MediaPanel/ColorTab/` (new), following `CaptionsTab/CaptionTab.swift`:
- Shown when an adjustment layer/clip is selected.
- **Layout A** (approved): collapsible **Basic Correction** (Temperature, Tint,
  Exposure, Contrast, Saturation) and **Creative** (LUT picker + Intensity)
  sections, each with an fx enable toggle, Premiere dark DA.
- All edits go through undoable `EditorViewModel` setters
  (`setColorGrade`/`setChromaKey`) mirroring `setTranscriptionLanguage`, calling
  `notifyTimelineChanged()` so preview rebuilds.
- "New Adjustment Layer" command (menu + timeline) adds an `.adjustment` track/clip.
- Chroma key controls: a small section on a normal clip's inspector (key color
  eyedropper, tolerance, softness, spill, edge feather).

### MCP

`Agent/Tools/ToolDefinitions.swift`: add `ToolName.setChromaKey = "set_chroma_key"`.
`Agent/Tools/ToolExecutor+ChromaKey.swift` (new): args `clipId` (required),
`enabled` (default true), optional `keyColorHex` (default green), `tolerance`,
`softness`, `spill`, `edgeFeather`; validates the clip exists and is visual;
mutates via the same `EditorViewModel.setChromaKey`. Mirrors existing tool
error/return conventions. Color grading is **not** exposed over MCP.

## Error handling

- Malformed `.cube` → typed `CubeLUTError`; UI import shows an alert, MCP/build
  logs and treats the LUT as absent (grade still applies the basic controls).
- Missing `lutRef` file at render → `lutResolver` omits it; basic controls still apply.
- Compositor failures per frame → log + finish with the un-graded accumulator
  (never crash the render).
- No color/key features present → built-in compositor path (unchanged).

## Testing

- `CubeLUT` parse: valid 3D cube, sizes, domain, comments, malformed inputs throw.
- `ColorGradePipeline`: neutral grade ≈ identity; intensity 0 == source; known
  control deltas move pixels in the expected direction (sample a 1×1 / small CIImage).
- `UltraKey`: green pixel → alpha≈0, subject pixel → alpha≈1; spill reduces green cast.
- Model: `Clip`/`ColorGrade`/`ChromaKey` round-trip; old JSON without the new
  fields decodes (defaults); adjustment clips create no composition tracks.
- Compositor smoke test: build a timeline with one video + adjustment layer and
  assert `customVideoCompositorClass` is set; one without color features asserts
  the built-in path (no custom compositor).

## Implementation phases (each ends build-green + tests-green)

1. **Pure core**: `CubeLUT` parser + `ColorGradePipeline` + `UltraKey` kernel,
   with unit tests. No app wiring. (Lowest risk, highest testability.)
2. **Model**: `ColorGrade`/`ChromaKey`/`.adjustment` + Codable round-trip + tolerant decode tests.
3. **Compositor**: `ColorVideoCompositor` + `ColorCompositionInstruction`;
   `buildVisuals` switches to custom path only when features are present; geometry
   parity check vs the built-in path on a no-color timeline.
4. **Chroma key end-to-end**: MCP `set_chroma_key` + minimal clip-inspector UI; verify preview keys out green.
5. **Color UI**: adjustment-layer creation + Lumetri panel (Layout A) + LUT import.
6. **Polish**: undo, edge cases, perf check on preview; docs.

PR target: fork `takefy-dev/palmier-pro`, branch `feat/color-grading-chroma-key` off `main`.

## Deviations from plan (as built)

1. **Chroma key uses a generated `CIColorCube`, not a Metal `CIKernel`.** SwiftPM
   can't compile `.ci.metal` without custom build flags; the cube bakes both the
   matte and spill suppression (Apple's documented keying approach). Pure-Swift,
   unit-tested, no toolchain risk. Edge feather is a `CIGaussianBlur` on the matte.
2. **LUT files are referenced by absolute path, not copied into the project.** The
   media resolver is manifest/asset-id based; wiring LUT copies through it was out
   of proportion for v1. `prebakeLUTs` resolves a manifest id *or* an absolute
   path, falling back gracefully (basic grade still applies) if the file moves.
   Follow-up: copy `.cube` into the project package for full portability.
3. **Geometry parity** for the custom compositor is verified by build + the
   identity/full-frame maths (the common case: full-frame video, full-frame grade,
   full-frame key). Arbitrary transform/crop on graded/keyed clips uses the
   flip-conjugated `affineTransform` and should be visually confirmed; non-rotated
   sources are correct by construction.

## Bonus (same render path)

Export gained **2K** and **Match Timeline** resolutions (`ExportResolution.r1440p`
/ `.native`) using HighestQuality presets that honour the composition render size.
Colour grades and chroma keys export because `ExportService` uses the same
`videoComposition`.
