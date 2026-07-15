# Timeline snapshot contract — v1

This is the normative schema for the flattened render snapshot that `PalmierPro.Services.Engine.TimelineSnapshotBuilder`
produces and that the native `PalmierEngine` will consume once its timeline ABI lands (E2). It is the
UI↔engine contract referenced by the Windows-port plan's "Timeline snapshot contract" section: C#
flattens and resolves everything media/nesting/multicam-related ahead of time; native never sees a
`.sequence` carrier, a multicam group, or an unresolved asset reference.

Producer: `TimelineSnapshotBuilder.Build(ProjectFile, timelineId, MediaResolver)` →
`TimelineSnapshotBuildResult { TimelineSnapshot Snapshot, IReadOnlySet<string> OfflineMediaRefs }`.
Serializer: `TimelineSnapshotSerializer.ToJsonBytes(TimelineSnapshot)` → deterministic UTF-8 bytes,
passed across the ABI in one call and parsed natively with simdjson (per the plan).

## 1. Top-level shape

```jsonc
{
  "version": 1,
  "fps": { "numerator": 30, "denominator": 1 },
  "outputWidth": 1920,
  "outputHeight": 1080,
  "tracks": [ /* SnapshotTrack, see §3 */ ]
}
```

- `version` — schema version. `1` for this document. Bump on any breaking shape change; native
  should reject an unrecognized version rather than guess.
- `fps` — `{ numerator, denominator }`. Swift's `Timeline.fps` is a single `Int` (frame-rate is
  always a whole number today), so v1 always emits `denominator: 1` and `numerator: timeline.Fps`.
  The two-field shape is reserved now so a future non-integer frame rate (23.976 = 24000/1001, NTSC
  29.97, etc.) is a value change, not a schema change.
- `outputWidth` / `outputHeight` — the timeline's canvas size in pixels (`Timeline.Width`/`Height`).
- `tracks` — ordered array, see §2 for the ordering convention and §3 for the shape.

## 2. Track ordering — READ THIS BEFORE WRITING A COMPOSITOR

**Verified convention (Swift source of truth):** `Sources/PalmierPro/Preview/PreviewHitTester.swift:23`
states outright — *"Video/image: track 0 is topmost (see CompositionBuilder)"* — and
`Editor/ViewModel/EditorViewModel+MediaLibrary.swift:776` / `Agent/Tools/ToolExecutor+Layout.swift:182`
independently confirm the same thing from the UI/agent side ("Index 0 is the topmost slot in the
timeline UI", "index 0 on top"). This is also derivable mechanically from
`CompositionBuilder.compositorInstructions`: it builds paint order via
`for track in timeline.tracks.reversed() where !track.hidden { … entries.append(...) }`, and
`FrameRenderer.composite` then paints `layers` **in array order**, later entries compositing
`over` the accumulator (`accum = image.composited(over: accum)`). Reversing `tracks` before
appending means the **highest** original track index is appended to `entries` first (painted
first → bottommost), and **index 0 is appended last** (painted last → topmost/frontmost). So:

> **`Timeline.tracks[0]` is the topmost/frontmost track. `Timeline.tracks[last]` is the
> bottommost/backmost track.**

**Snapshot's own convention (deliberate, and different from the above):** `TimelineSnapshot.tracks`
is written in **paint order — index 0 first/bottom, last index painted last/top** — i.e. it is
`reverse(Timeline.tracks)`, not a direct copy. `TimelineSnapshotBuilder` performs this reversal
once, at serialization time (it iterates `timeline.Tracks` in Swift's index-0-is-top order to build
each lane, but appends finished lanes into the *output* list such that paint order comes out
correct — see the implementation note below). This choice mirrors `FrameRenderer.composite`'s own
loop (`for layer in layers { accum = image.composited(over: accum) }`) exactly, so the native
compositor can do the simplest possible thing:

```
accum = black
for track in snapshot.tracks:      // forward, index 0 → last
    for clip in track.clips where clip spans the current frame:
        accum = composite(clip, over: accum, blendMode: clip.blendMode)
```

No reverse-iteration, no special-casing, on the native side. This is the one piece of this
contract most likely to cause an inverted (upside-down z-order) render if gotten wrong — golden
fixtures MUST include a two-track overlap case (opaque clip on the Windows-UI-topmost track over a
different-colored clip on the bottommost track) to catch a regression here.

*(Implementation note for `TimelineSnapshotBuilder`: because nested-sequence flattening (§4) can
splice extra synthetic tracks into the middle of the list, the builder does not literally call
`.Reverse()` on a pre-built list — it emits lanes in an order that already satisfies the
bottom-to-top invariant above. Track-ordering unit tests assert the *effective* paint order, not
the literal code path.)*

## 3. `SnapshotTrack`

```jsonc
{
  "id": "TRACK-1",
  "type": "video",          // ClipType raw value: "video" | "audio" (only these two occur as a *track* type)
  "muted": false,
  "clips": [ /* SnapshotClip, see §5 */ ]
}
```

- `id` — for a track that maps 1:1 to a `Timeline.Track` (i.e. every track that isn't purely the
  product of nested-sequence flattening), this is `Track.Id` verbatim. For a synthetic track
  produced by flattening (§4), it's `"{carrierClipId}#v{n}"` / `"{carrierClipId}#a{n}"` — see §4.
- `type` — `"video"` or `"audio"`. (Never `"image"`/`"text"`/`"lottie"`/`"sequence"` — those are
  *clip* types that live on a `"video"`-type track, or are excluded/expanded away before this
  point.)
- `muted` — **audio tracks only** (meaningless/always `false` for a `"video"`-type track). `true`
  means every clip on this track should render at zero gain. Unlike the Mac (which keeps muted
  clips in the composition and zeroes gain via `AVMutableAudioMixInputParameters`), the *reason*
  to still enumerate the clips rather than dropping the track is identical: so unmuting is a
  param-only change (§7), not a rebuild.
- `clips` — ordered by `startFrame`; clips on one track never overlap (this is a Timeline invariant
  the builder enforces the same way `CompositionBuilder` does — an out-of-order or overlapping
  clip is silently dropped, matching `guard clip.startFrame >= previousEndFrame`). Note the two
  lanes advance `previousEndFrame` differently, matching an asymmetry in `CompositionBuilder`
  itself: the audio lane (`EmitAudioLane` / `insertAudioLane`) advances it unconditionally for
  every clip, so an offline/unresolvable audio clip still "consumes" its span and can shadow a
  later overlapping clip. The video lane (`EmitVideoLane` / `insertVideoLane`) advances it only
  for a sequence carrier or a *successfully resolved* clip — an offline/unprocessable video clip
  does not consume its span, so a later overlapping clip can still be emitted. This is only
  observable on invariant-violating (overlapping) input.

**A schema-level deviation from `Track`'s literal field list is deliberate here:** the plan's
starting point named `blendMode` as a per-track field. That's wrong — verified against
`Sources/PalmierPro/Models/Timeline.swift:184` (`var blendMode: BlendMode?` is a `Clip` property)
and `Sources/PalmierPro/Compositing/FrameRenderer.swift:46` (`let mode = layer.clip.blendMode ?? .normal`
— read off the *clip*, never the track). `Track` has no `blendMode` in the Swift model at all.
This schema places `blendMode` on `SnapshotClip` (§5) instead, and adds `type` to `SnapshotTrack`
(not in the plan's literal list, but cheap and makes the JSON self-describing without clip
inspection) — flagged here explicitly since it's a deviation from the literal brief, not an
oversight.

## 4. Nested-sequence flattening (`NestFlattener` port)

`TimelineSnapshotBuilder` ports `Preview/NestFlattener.swift` faithfully: same one-level "remap
child clips into parent frame coordinates" algorithm (frame-window intersection, `trimStartFrame`
shift by `headCut × speed`, fade-clearing at a cut edge, `maxDepth = 8`, muted-child-track /
hidden-child-track filtering), recursed for arbitrarily deep `.sequence` nesting exactly as
`CompositionBuilder.expandNestVideo`/`expandNestAudio` do. See `Engine/NestFlattener.cs`.

**Nest-trigger field differs between the two lanes — easy to get backwards.** The video lane
detects a nest via `Clip.MediaType == .Sequence` (`CompositionBuilder.insertVideoLane`:
`clip.mediaType == .sequence`). The audio lane detects it via `Clip.SourceClipType == .Sequence`
instead (`insertAudioLane`: `clip.sourceClipType == .sequence`) — because `.sequence` clips are
`ClipType.IsVisual == true`, they're never placed directly on an audio-type track; a nest's audio
only reaches an audio-type track as a **derived "detached audio" clip**, where `MediaType` has
become `.Audio` but `SourceClipType` still remembers `.Sequence` (the field Swift's model
docs as "original media type for derived clips; used for color-coding" — `Models/Timeline.swift`).
Both fields carry the same `MediaRef` (the child timeline's id) regardless of which one is
`.Sequence`. `EmitVideoLane` gates on `MediaType`; `EmitAudioLane` gates on `SourceClipType` — this
is not a typo, and unifying them to check the same field would silently break either
plain-video-track nesting or detached-audio nesting depending on which way it was "fixed."

**What v1 does NOT do (a deliberate, documented simplification vs. the Mac):** on the Mac, a
`.sequence` clip's *own* `opacity`/`crop`/`transform`/`effects` are applied as a single unit over
the *composited result* of its flattened children (`FrameRenderer.composedGroupLayer` — the nest
renders to its own child-canvas-sized intermediate, then that whole intermediate gets the
carrier's transform/crop/opacity/effect chain). `NestFlattener.remap` itself never touches those
fields — it is purely a time/trim remap. v1's builder ports only `NestFlattener.remap`, matching
the plan's literal scope ("ports NestFlattener faithfully"); it does **not** reconstruct the
group-layer wrapper `CompositionBuilder`/`FrameRenderer` build on top of it. Concretely:

- A flattened child clip's `opacity`/`transform`/`crop` are emitted **unmodified from the child's
  own authoring** — the carrier's own opacity/crop/transform are dropped in v1.
- If a nested sequence's own canvas (`Timeline.Width`/`Height`) differs from the root timeline's,
  v1 does **not** rescale the child's `transform`/`crop` to compensate — they stay normalized
  against the *child's* canvas. This will misplace/mis-scale content when a nested sequence's
  aspect ratio differs from the root's.

  Full parity (child composited at its own canvas size, carrier's pipeline applied as a unit, then
  placed into the parent) is real render-graph work and lands with E3's "nested-sequence
  flattening pre-pass" milestone on the native side.

**What v1 DOES fold in (an exception, and it's exact, not approximate):** each ancestor `.sequence`
carrier's own **static** `Clip.Volume` scalar is multiplied into every descendant leaf audio clip's
emitted `volume.gain` (§5), at every nesting level uniformly. This is safe to do exactly — unlike
opacity/crop compositing, gain is genuinely commutative/multiplicative across a nest boundary, so
`carrier.Volume × child.Volume × …` is not an approximation. (The Mac's actual behavior is more
elaborate — the *immediate* ancestor's full fade/keyframe envelope is folded in at mix time via
`emitVolumeEnvelope`'s `carrier` parameter, using `Clip.volumeAt(frame:)`, while only *deeper*
ancestors get static-only folding via `expandNestAudio`'s `volumeScale` chain. v1 cannot replicate
the per-frame envelope half of that without keyframe support, so it applies the static-only rule
uniformly at every level instead of the Mac's first-level-special-cased version — simpler, and
strictly more complete than doing nothing.) Ancestor carriers' own `fadeInFrames`/`fadeOutFrames`
are **not** folded into descendants — a fade is inherently time-varying and cannot be represented
as a single static gain multiplier, so this isn't a choice, it's a hard limitation until E3.

**Track splicing / IDs.** A nest's flattened video (or audio) sub-tracks (`NestFlattener.Flattened.VideoTracks`/
`AudioTracks`, itself a `[[Clip]]` exactly like the Swift `Flattened` struct) are spliced into the
output as their own `SnapshotTrack`s, one per flattened sub-track, with synthetic ids
`"{carrierClipId}#v{n}"` (video) / `"{carrierClipId}#a{n}"` (audio), where `n` is the sub-track's
index within that nest (`0` = the child timeline's own topmost video track, per §2's convention,
recursively — `NestFlattener.Flatten`'s per-carrier sub-track order is untouched by the builder).
The `{carrierClipId}` prefix (not the child timeline's id) guarantees a unique id even when the
same compound clip is nested twice in the same project — this mirrors `NestFlattener.remap`'s own
clip-id uniquification (`"\(nestId)/\(clip.id)"`) for exactly the same reason.

*Why splice-anywhere is safe:* a single `Track`'s clips never overlap in time (a Timeline
invariant), so at most one of {a track's own non-sequence clips, one particular `.sequence`
clip's flattened content} is ever "live" at a given frame. Relative paint order between a track's
own lane and its nested sub-lanes therefore cannot matter for correctness — the only order that
*does* matter is preserved: the relative order of one nest's own sub-tracks against each other
(§2's convention, recursively).

**Missing child timeline.** If a `.sequence` clip's `mediaRef` doesn't resolve to any
`ProjectFile.Timelines[].Id`, its `mediaRef` is added to `offlineMediaRefs` and the clip is
skipped — mirrors `CompositionBuilder.expandNestVideo`'s `ctx.offlineMediaRefs.insert(carrier.mediaRef)`
fallback exactly.

## 5. `SnapshotClip`

```jsonc
{
  "id": "L1CARRIERID/L2CLIPID",
  "type": "video",                 // ClipType raw value: "video" | "audio" | "image" — never
                                    // "text" / "lottie" / "sequence" (see §6)
  "startFrame": 0,
  "durationFrames": 90,
  "trimStartFrame": 0,
  "speed": 1.0,
  "mediaPath": "C:\\Users\\me\\Movies\\clip-a.mp4",   // ABSOLUTE, pre-resolved (§8)
  "hasAlphaHint": null,             // bool | null — see below
  "blendMode": null,                // BlendMode raw value | null ("normal" is encoded as null, matching Swift's `Clip.blendMode == nil` meaning normal/source-over)
  "opacity": { "value": 1.0, "keyframes": null },
  "transform": {
    "value": {
      "centerX": 0.5, "centerY": 0.5, "width": 1.0, "height": 1.0,
      "rotation": 0.0, "flipHorizontal": false, "flipVertical": false
    },
    "keyframes": null
  },
  "crop": {
    "value": { "left": 0.0, "top": 0.0, "right": 0.0, "bottom": 0.0 },
    "keyframes": null
  },
  "volume": {
    "gain": 1.0,
    "fadeInFrames": 0,
    "fadeOutFrames": 0,
    "fadeInInterpolation": "linear",
    "fadeOutInterpolation": "linear",
    "keyframes": null
  }
}
```

Field-by-field:

- `id` — `Clip.Id`, or the nest-prefixed id from §4 for a flattened clip.
- `type` — the clip's `MediaType` raw value. Always `"video"`, `"audio"`, or `"image"` in v1 (text
  and lottie are filtered out before this point — §6; `.sequence` clips never reach here, they're
  expanded per §4).
- `startFrame`, `durationFrames`, `trimStartFrame`, `speed` — carried straight from `Clip`
  (post-flatten values for a nested clip — see §4's remap semantics). `trimEndFrame` is **not**
  included: it's derivable (`sourceDurationFrames - sourceFramesConsumed - trimStartFrame`, and
  even that only matters for editing UI, not playback) and the engine never needs it to render —
  omitted rather than carried as dead weight.
- `mediaPath` — absolute, OS-native path. See §8 (media resolution) — the engine never resolves an
  asset ref itself; every clip that reaches the output has already been proven to point at an
  existing file.
- `hasAlphaHint` — `true` / `false` / `null`. A **coarse, non-authoritative** hint, computed
  cheaply from the file extension for `"image"` clips only (`.png`/`.webp`/`.tiff` → `true`,
  `.jpg`/`.jpeg` → `false`, anything else including `.heic` → `null`/unknown). Always `null` for
  `"video"`/`"audio"` clips — alpha for video is determined authoritatively by the engine from the
  decoded codec/pixel format at decode time (mirrors the Mac's `AlphaVideoNormalizer`, which
  inspects `kCMFormatDescriptionExtension_ContainsAlphaChannel`, i.e. the actual bitstream, not a
  file-extension guess). Treat this field as an optimization hint only, never as ground truth.
- `blendMode` — the `BlendMode` raw value (`"normal"`, `"darken"`, `"multiply"`, …), or `null`.
  `null` here means "not set" and renders identically to `"normal"` — matching Swift's own
  `Clip.blendMode: BlendMode?` where `nil` means normal/source-over (`FrameRenderer.swift:46`:
  `let mode = layer.clip.blendMode ?? .normal`). The engine should treat `null` and `"normal"` as
  the same thing; the builder always emits `null` rather than the literal string `"normal"` to
  mirror the Swift nil-means-default convention exactly.
- `opacity` / `transform` / `crop` — each wrapped in a `{ "value": …, "keyframes": null }` envelope.
  **v1 is static-only: `keyframes` is always `null`.** The envelope shape is reserved now so E3 can
  populate `keyframes` (shape: `[{ "frame": int, "value": <same type as "value">, "interpolationOut":
  "linear"|"hold"|"smooth" }]`, mirroring `Keyframe<V>`/`KeyframeTrack<V>` exactly) without a
  breaking schema change — this directly implements the plan's "reserve the field shapes" note.
  `transform.value` mirrors `Transform` field-for-field (`rotation` in degrees, positive =
  clockwise, matching Swift). `crop.value` mirrors `Crop` (normalized 0–1 edge insets) field-for-field.
- `volume` — bundles every **static** audio-relevant field:
  - `gain` — linear amplitude multiplier. For an audio clip, this is `Clip.Volume` already folded
    with any ancestor `.sequence` carriers' static volume (§4) — **not** just `Clip.Volume` in
    isolation for a nested clip. For a video/image clip this is `Clip.Volume` verbatim (unused by
    rendering; carried through because the field exists on every `Clip` in the Swift model too —
    dead but harmless, kept for schema uniformity rather than special-cased away per clip type).
  - `fadeInFrames` / `fadeOutFrames` / `fadeInInterpolation` / `fadeOutInterpolation` — verbatim
    from `Clip` (post-flatten — a fade is zeroed at whichever edge a nest window cut through, per
    §4/`NestFlattener.remap`).
  - `keyframes` — the dB keyframe track (`Keyframe<Double>` shape, dB values, `Clip.VolumeTrack` in
    the Swift model). `null` in v1; **populated as of E4.5** (audio playback) using the identical
    `{ "frame", "value", "interpolation" }` envelope shape as `opacity`/`crop` (§11.2) — see the
    §5.1 addendum below for the sampling contract. Static clips still emit `null`.
  - **Why volume is present at all before E4.5 (audio playback) lands:** the fields are part of
    the schema now so the engine doesn't need another ABI-shape change once E4.5 starts consuming
    them — v1's native side is free to ignore this object entirely today.

### 5.1 Volume dB keyframe track (E4.5)

The audio mixer (docs/audio-playback-v1.md §1) computes each clip's effective linear gain as
`gain(frame) = volume.gain × VolumeScale.linearFromDb(volumeKeyframes.sample(frame)) × fadeMultiplier(frame)`,
mirroring `Clip.VolumeAt` (`Timeline.cs:320`) exactly. The `volume.keyframes` array closes the one
schema gap §5 left open, additively and by the **same** mechanical rules as §11.2's
opacity/crop/transform envelopes:

- **Producer** — `TimelineSnapshotBuilder.TryResolveClip` populates it with
  `BuildKeyframes(clip.VolumeTrack, kf => kf.Value)`, the identical call opacity/crop already use;
  `TimelineSnapshotSerializer.WriteClip` writes it with the shared `WriteDoubleKeyframes` helper (an
  array of `{ frame, value, interpolation }`, or `null` when the track is inactive). `frame` is
  clip-relative; `value` is **dB**, not linear.
- **Consumer** — `TimelineSnapshotParser` reads it into `SnapshotClip.volumeKeyframes` with the same
  `ParseKeyframesArray` opacity uses; `AudioMixer` samples it via `SampleKeyframeTrack`
  (`Keyframe.h`, dB fallback `0.0` == unity) and maps the sampled dB through the
  `VolumeScale.linearFromDb` port (clamp `[-60, +15]` dB, floor == hard mute). An empty/absent array
  is unity gain — byte-for-byte the pre-E4.5 static behavior.
- **Not sampled per-sample** — gain (this term included) is evaluated at **block cadence** (one 20 ms
  mix block, docs/audio-playback-v1.md §2), not per output sample, so a keyframed or fading gain
  moves in per-block steps. This matches the doc's own "sampled at block cadence" wording and is
  inaudible at 20 ms granularity.
- The `fadeInFrames`/`fadeOutFrames`/`fadeIn|OutInterpolation` fields (already present since v1) are
  the mixer's fade-envelope input, ported verbatim as `Clip.FadeMultiplier` (`Timeline.cs:342`).
  Native now parses them (it ignored the whole `volume` object through v1.1).

## 6. Excluded clip types

- **Text** (`ClipType.Text`) — excluded entirely in v1/v1.1 (**superseded in v1.2 — see §12**: a
  text clip now enters the snapshot via its originating `SnapshotTrack`'s `textClips` list, not
  `Clips`). On the Mac, text never becomes a *composition track* either
  (`CompositionBuilder.build`'s `.filter { $0.mediaType != .text }`) — it renders through a
  separate Direct2D/DirectWrite text-compositing path, which is E4 ("Text/titles") on the Windows
  roadmap. Under v1/v1.1, a text clip contributed nothing to the snapshot at all: no track, no
  clip entry, no `offlineMediaRefs`/`unprocessableMediaRefs` entry (it isn't a media reference at
  all) — v1.2 keeps the "not a media reference" part (still no `offlineMediaRefs` entry) but stops
  dropping the clip's data on the floor.
- **Lottie** (`ClipType.Lottie`) — excluded entirely in v1, v1.1, **and v1.2** (unchanged by this
  section). This is a genuine **divergence from the Mac**, not a mirror of existing Mac behavior:
  `CompositionBuilder` *does* composite Lottie clips today (baked to an alpha-video intermediate
  via `LottieVideoGenerator`, then treated as ordinary footage). The Windows ThorVG bake pipeline
  is E4.7 and doesn't exist yet, so the builder skips Lottie clips rather than emitting a clip the
  engine has no way to render. Skipped Lottie clips are **not** added to
  `offlineMediaRefs`/`unprocessableMediaRefs` — that would misreport a known, tracked gap as a
  missing-file error. A project with Lottie clips still opens and plays (Phase 1 requirement); the
  Lottie clips are simply invisible/silent until E4.7.

Through v1.1, both exclusions happened identically — `RenderableClips` filtered `MediaType is
ClipType.Text or ClipType.Lottie` out of a clip list before it was walked, inside
`EmitVideoLane`/`EmitAudioLane` themselves so every entry point (the top-level per-track loop AND
every recursive nested-sub-track call out of `ExpandNestVideo`/`ExpandNestAudio`) applied it
identically. **As of v1.2, `EmitVideoLane` inlines its own Text/Lottie branch instead of calling
`RenderableClips`** (Text now needs to route to `ctx`'s per-track `textClips` output rather than
simply being dropped) — `EmitAudioLane` is unaffected and still calls `RenderableClips` (Text and
Lottie are both `ClipType.IsVisual`, so neither is ever audio-lane-eligible; the audio lane keeps
filtering both defensively against a malformed/legacy project). See §12 for the full text-clip
rationale, including why nested-sub-track recursion for text needed no new code at all.

## 7. Multicam clips — resolution is a no-op

The plan's brief describes this builder as "resolving multicam clips to the active angle's
concrete media." Having read `Editor/ViewModel/EditorViewModel+Multicam.swift` and
`Timeline/MulticamEngine.swift`, **there is no runtime multicam resolution step to port** — it's
already baked into the data by the time a `TimelineSnapshotBuilder` ever sees it:

- Angle switching (`MulticamEngine.switchMulticamSegment`/`switchMulticamAngles`) works by
  **destructively rewriting the clip's own `mediaRef`/`trimStartFrame`/`trimEndFrame`**
  (`MulticamEngine.rewrite(_:group:to:sourceDurations:fps:)`) at the moment the user switches
  angles. The clip that ends up on the timeline always points at whichever angle is currently
  active — there is no separate "active angle" indirection for a renderer to resolve at playback
  time.
- Confirmed independently: `CompositionBuilder.swift` (searched in full) contains no multicam-aware
  code path at all — a multicam-group clip is composited by `insertVideoLane`/`insertAudioLane`
  exactly like any other clip, keyed only off `clip.mediaRef`.

So `TimelineSnapshotBuilder` treats a clip carrying a non-null `MulticamGroupId` exactly like any
other video/audio clip: resolve `MediaRef` → absolute path (§8), emit. `MulticamGroupId` itself is
**not** part of the v1 schema (nothing downstream needs it — Phase 1 multicam is playback-only, no
angle-switching UI exists yet per the plan's explicit Phase 2 deferral). This matches the plan's
own parenthetical: "mirror CompositionBuilder's resolution — playback only, no editing."

## 8. Media resolution and `offlineMediaRefs`

Every clip's `MediaRef` is resolved via `MediaResolver.ResolveUrl(mediaRef)` — this single call
mirrors **both** of the Mac's failure modes in one check (`CompositionBuilder.loadSource`'s
`missingMediaRefs.contains(clip.mediaRef)` **and** its `resolveURL(clip.mediaRef) == nil`): it
returns `null` if there's no manifest entry for the ref *or* if the manifest entry's expected path
doesn't exist on disk. If it returns `null`, the ref is added to the builder's `OfflineMediaRefs`
result set and **the clip is skipped** (not emitted at all — not emitted-with-a-null-path). If it
returns a path, that absolute path is what's written into `mediaPath` — verbatim, OS-native
separators, no further transformation.

**`offlineMediaRefs` vs. `unprocessableMediaRefs` — split of responsibility.** The Mac's
`CompositionBuilder` also produces `unprocessableMediaRefs` (file exists on disk, but some
required preprocessing step failed — e.g. `ImageVideoGenerator.stillVideo` throwing while the
source image file is present). `TimelineSnapshotBuilder` has no equivalent preprocessing step in
v1 (no still-image baking, no Lottie baking — see §6) and so **never produces
`unprocessableMediaRefs`** — that side of `IVideoEngine.MediaStatus` (see `IVideoEngine.cs`) is
populated exclusively by the native engine, from decode-time failures the C# side has no way to
predict ahead of time (a corrupt file, an unsupported codec, etc.). `offlineMediaRefs` is
exclusively a C#-side, path-resolution-time concept. `IVideoEngine.MediaStatusChanged` unions both
sources for the UI to display as one list.

## 9. Determinism

`TimelineSnapshotSerializer.ToJsonBytes` writes every object with a **fixed, hand-written key
order** via `Utf8JsonWriter` calls in source order — no `JsonSerializer` reflection anywhere in the
write path. Keyframe collections (`KeyframeTrack<T>`, §11.2) are list-shaped, so they need nothing
special: array order is source/insertion order already.

One field IS dictionary-shaped, as of v1.1 (§11.3): `Effect.Params` is a
`Dictionary<string, EffectParam>`, and `WriteEffect` (`TimelineSnapshotBuilder.cs`) iterates it.
`Dictionary<TKey,TValue>` enumeration order is not a stable .NET contract, so that loop does NOT
rely on it — it explicitly sorts first: `effect.Params.OrderBy(kv => kv.Key,
StringComparer.Ordinal)`. That sort, not enumeration order, is what keeps `params` deterministic;
if a future dictionary-shaped field is added to this schema without the same explicit sort, this
guarantee does not extend to it automatically.

Same `ProjectFile` + `MediaResolver` state in ⇒ byte-identical JSON out, every time. This is
asserted by a golden-fixture test (`TimelineSnapshotBuilderTests`) that builds a snapshot twice from
the same inputs and compares bytes, and separately (`EffectParamsSerializeInOrdinalKeyOrder_
RegardlessOfInsertionOrder`) by inserting `Effect.Params` entries out of alphabetical order and
asserting the serialized key order is alphabetical regardless — the golden fixtures' own params
happen to already be inserted in alphabetical order, so they alone don't exercise the sort.

## 10. Golden fixtures

`platforms/windows/tests/PalmierPro.Services.Tests/Engine/Fixtures/` contains checked-in, hand-verified
example snapshot JSON the native agent can parse in its own (simdjson) tests once the timeline ABI
lands:

| File | Demonstrates |
|---|---|
| `simple-two-track.snapshot.json` | Baseline shape: one video + one audio top-level track, track/clip field layout, the `{value, keyframes}` / `volume` envelopes, `blendMode: null` |
| `nested-sequence.snapshot.json` | §4 flattening: a `.sequence` clip's child timeline (2 video sub-tracks) spliced in with remapped `startFrame`/`trimStartFrame`, nest-prefixed clip and track ids |
| `missing-media.snapshot.json` | §8: one clip whose manifest entry points at a nonexistent file — clip skipped, empty track omitted entirely, ref surfaced only via the separate (non-JSON) `OfflineMediaRefs` result |
| `effects-and-keyframes.snapshot.json` | §11 (v1.1): populated opacity/crop/transform keyframe envelopes plus a per-clip effect with one static and one keyframed param |
| `text-clip.snapshot.json` | §12 (v1.2): a dedicated text-only track (`clips: []`, populated `textClips`) painting over a video track beneath it — full `style`/`animation`/`wordTimings`, a keyframed `opacity` envelope, `minorVersion: 2` |

Every `mediaPath` value in these files is templated as the literal token `{{FIXTURE_DIR}}` in place
of the absolute directory used when the fixture was generated (e.g.
`"{{FIXTURE_DIR}}\\clip-a.mp4"`) — substitute your own absolute path before parsing. **The token
sits inside a JSON string, so a Windows path substituted in must be JSON-escaped first** (`\` →
`\\`) or the substitution corrupts the surrounding string's escaping — a raw string-replace of a
literal `C:\Users\...` path will NOT produce valid JSON. `TimelineSnapshotBuilderTests`'s
`LoadGolden` helper shows the correct substitution.

## 11. v1.1 extension — keyframed params + per-clip effects (E3)

E3 (GPU effect/compositing pipeline) extends the schema **additively**: every v1 fixture is still
valid v1.1 input (all-`null` keyframes, no `effects` key, absent `minorVersion`). Both sides —
`TimelineSnapshotBuilder`/`TimelineSnapshotSerializer` (C#) and `TimelineSnapshotParser`/
`GpuCompositor` (native) — implement this section identically.

### 11.1 `minorVersion`

Top-level `version` stays `1`. A new optional `"minorVersion": 1` sits alongside it
(`TimelineSnapshotBuilder.SchemaMinorVersion`). **Native treats an absent `minorVersion` as `0`
and never rejects on this field** — `TimelineSnapshotParser` reads it with the same
`GetInt64Or(..., default: 0)` helper every other optional field uses, and nothing downstream
branches on its value (a v1.1 producer emitting an all-static clip is byte-for-byte
indistinguishable, render-wise, from a real v1 producer).

### 11.2 Populated keyframe envelopes

The `{ "value": ..., "keyframes": null }` envelope already existed in v1 for `opacity`/
`transform`/`crop` (§5) — v1 only ever emitted `null`. v1.1 populates it:

```jsonc
"opacity": {
  "value": 1.0,
  "keyframes": [
    { "frame": 0, "value": 0.0, "interpolation": "linear" },
    { "frame": 30, "value": 1.0, "interpolation": "smooth" }
  ]
}
```

- `frame` — **clip-relative** (`timelineFrame - clip.startFrame`), matching `Keyframe.swift`'s
  `toOffset` storage convention (Core's `KeyframeTrack<T>.Keyframes[i].Frame` is ALREADY
  clip-relative at rest — the builder emits it verbatim, no re-basing).
  `value` — same shape as the envelope's own `value` field (a number for opacity, a `Crop`/
  `Transform` object for those envelopes).
- `interpolation` — `"linear"` | `"hold"` | `"smooth"`, mirroring `Keyframe.InterpolationOut`
  (note: the wire key is `interpolation`, not Core's `interpolationOut` — this is the engine ABI's
  own contract, hand-written like every other object in this schema, not a reflection of Core's
  project-file JSON).
- Sampling rules (native `SampleKeyframeTrack`, `Keyframe.h`) mirror `KeyframeTrack<T>.Sample`
  (`Keyframe.cs`/`Keyframe.swift`) exactly: empty → the envelope's `value`; before the first
  keyframe → the first keyframe's value; after the last → the last keyframe's value; between two
  keyframes → hold (left value) / linear / smooth (`t*t*(3-2t)`) per the LEFT keyframe's
  `interpolation`.

**`opacity`** and **`crop`** map directly onto Core's own `Clip.OpacityTrack`
(`KeyframeTrack<double>`) and `Clip.CropTrack` (`KeyframeTrack<Crop>`) — one Swift/C# track, one
wire envelope, sampled with that track's own interpolation at every point. No approximation.

**`transform`** has no single Core/Swift equivalent — the Mac tracks position (`AnimPair`), scale
(`AnimPair`), and rotation (`double`) as **three separate** `KeyframeTrack`s on `Clip`, never one
compound "transform" track. `TimelineSnapshotBuilder.BuildTransformKeyframes` merges them for wire
simplicity: at the **union** of every keyframe frame across `PositionTrack`/`ScaleTrack`/
`RotationTrack`, it samples the **full** `Transform` via `Clip.TransformAt(frame)` — which already
independently and correctly samples each of the three underlying tracks with **its own**
interpolation mode — so every emitted anchor point is an exact sample, never an approximation. The
one deliberate, documented simplification: the **curve shape between two merged anchors** is
always re-interpolated **linearly** on the combined `Transform` (`interpolation: "linear"` on every
emitted transform keyframe) rather than reproducing three independent smooth/hold segments that
may not share anchor points. Concretely: if only `ScaleTrack` is keyframed (position/rotation
static), the merged transform keyframes exactly reproduce the scale curve (position/rotation
anchors are identical at every point, so linear interpolation between them is a no-op); the
approximation only bites when position/scale/rotation are keyframed at **different, non-aligned**
frames with **non-linear** (smooth) interpolation on the Swift/C# side — a rare combination, and
strictly better than v1's total silence on transform keyframes.

### 11.3 `effects`

Each `SnapshotClip` gains an optional, ordered `"effects"` array (omitted when empty — matches
`Clip.Effects` being `null`/empty on the Swift/C# side):

```jsonc
"effects": [
  {
    "type": "color.blacksWhites",
    "enabled": true,
    "params": {
      "blacks": { "value": 0.2, "string": null, "keyframes": null },
      "whites": { "value": null, "string": null, "keyframes": [
        { "frame": 0, "value": -0.3, "interpolation": "hold" },
        { "frame": 60, "value": 0.4, "interpolation": "linear" }
      ] }
    }
  }
]
```

- `type` — `Effect.type` raw string verbatim (e.g. `"color.blacksWhites"`, `"stylize.vignette"`) —
  see `EffectRegistry.swift` for the full id list and `native/EffectRegistry.h` for the native
  table of the 11 ids E3 actually renders (every other registered id is parsed but silently
  skipped by `GpuCompositor` — not an error, matches "an effect chain may reference an effect kind
  a given engine build doesn't implement yet").
- `enabled` — disabled effects are parsed but never dispatched.
- `params[name]` — **not** Core's project-file `EffectParam` shape (that uses a `"track"` key);
  this is the engine ABI's own `{ value, string, keyframes }` shape, matching §11.2's envelope
  convention. `value`/`string` mirror `EffectParam.Value`/`StringValue`. `keyframes` (when
  non-null) is a `KeyframeTrack<double>` — **only numeric params keyframe**; `string` params
  (`curve`/`curves`/`path` — GradeCurves/HueCurves control-point JSON, LUTTetra's `.cube` path)
  are always static.
- Ordering matters (effects apply in array order, matching `Clip.Effects`'s list order — see
  `EffectRegistry.canonicalOrder`/`insertIndex`, which the Swift inspector already enforces when
  inserting a new effect).

Native evaluates every numeric param per frame via `SnapshotEffectParam::Resolve` (`Keyframe.h`'s
`SampleKeyframeTrack`, identical semantics to §11.2), clamped to the param's registered
`(rangeMin, rangeMax)` — mirrors `EffectDescriptor.resolve`'s clamp (`EffectRegistry.swift`)
exactly — then fills the effect's HLSL constant buffer (`GpuCompositor.cpp`).

### 11.4 Compatibility

A v1 producer (no `minorVersion`, all keyframes `null`, no `effects`) parses and renders
identically under v1.1 native code — `SnapshotClip::OpacityAt`/`CropAt`/`TransformAt` all
special-case "keyframes empty → return the static `value`" as their first branch, and an empty
`effects` list is simply "no effect chain to run" (§11.3's E3 render path, `GpuCompositor::Compose`
— see the E3 milestone report for what's GPU-default vs. CPU-fallback-only).

## 12. v1.2 extension — text clips (E4)

E4 ("Text/titles" on the Windows roadmap) extends the schema **additively over v1.1**, exactly the
way v1.1 extended v1 (§11): every v1/v1.1 fixture is still valid v1.2 input (no `textClips` key on
any track). Text clips (`ClipType.Text`) now enter the snapshot — they were structurally excluded
through v1.1 (§6). This section covers the C#-side (`TimelineSnapshotBuilder`/
`TimelineSnapshotSerializer`) contract; **native text parsing/rendering is out of scope here** —
that is E4's own (separate) work. The only native-side change this section makes is confirming the
parser doesn't choke on the new data (§12.6).

### 12.1 `minorVersion`

Bumped to `"minorVersion": 2` (`TimelineSnapshotBuilder.SchemaMinorVersion`). Top-level `version`
stays `1`, unchanged (v1.2 is a minor-version bump, not a schema-breaking change). Native's version
gate (`TimelineSnapshotParser::Parse`) only ever validated the top-level `version` field
(`if (version != 1) reject`) — it has never validated `minorVersion` at all (an absent OR any
unrecognized numeric `minorVersion` has always resolved to "no keyframes/effects," §11.1's
established convention). **Bumping to 2 required zero changes to the version gate** — it was
already permissive enough. (`TimelineSnapshot.h`'s doc comment on `minorVersion` was updated to
mention "2 = v1.2" for documentation accuracy only; that's a comment-only diff.)

### 12.2 Where a text clip lives: `SnapshotTrack.textClips`, not `SnapshotTrack.clips`

A text clip is **not** a `SnapshotClip` and does **not** live in a track's `clips` array. Two
reasons, both hard requirements rather than style preferences:

1. **`mediaPath` has no meaning for text.** `SnapshotClip.mediaPath` is `required`
   (`ParseClip` in `TimelineSnapshotParser.cpp` rejects the *entire* snapshot if any clip's
   `mediaPath` is empty — `outError = "clip '<id>' has an empty mediaPath"`). A text clip is
   synthesized at render time from font/content, not decoded from a file — there is no path to
   put there, and inventing a placeholder would either lie about having a media reference or
   require changing that validation rule (§12.6 explains why that's explicitly avoided).
2. **Paint order must be preserved without inventing a new ordering scheme.** On the Mac,
   `CompositionBuilder.compositorInstructions` builds its `layers` array **per track**, walking
   `timeline.tracks.reversed()` (§2's bottom-to-top order) and, *within* that per-track walk,
   appending each track's own clips **and** its text clips into the same `entries` list in
   `startFrame` order (`Preview/CompositionBuilder.swift`, the "Walk tracks in reverse..." loop
   — search the comment literally). A text clip's stacking position is therefore governed by
   **which track it was authored on**, exactly like an ordinary clip — a caption track above the
   video paints over it; a caption track below a video track would paint under it. A flat,
   track-agnostic `textClips` array at the top level (the schema's first design considered) would
   have thrown this information away. Attaching `textClips` to the `SnapshotTrack` that produced
   it — the same `SnapshotTrack` whose position in the top-level `tracks[]` array already encodes
   correct paint order per §2 — reuses that ordering with **zero new concepts**: whichever
   `SnapshotTrack` a text clip's `EmitVideoLane` call is currently processing is exactly the track
   it inherits z-order from, including a nest-spliced synthetic track (§4) — a text clip nested
   inside a `.sequence` lands on `"{carrierClipId}#v{n}"` exactly like a nested video clip would.

```jsonc
{
  "id": "TRACK-TEXT",
  "type": "video",
  "muted": false,
  "clips": [],
  "textClips": [
    {
      "id": "TEXT-CLIP-1",
      "startFrame": 15,
      "durationFrames": 60,
      "content": "Hello world",
      "opacity": { "value": 1.0, "keyframes": [ /* §12.3 */ ] },
      "blendMode": null,
      "transform": { "centerX": 0.5, "centerY": 0.9, "width": 0.8, "height": 0.2,
                      "rotation": 0.0, "flipHorizontal": false, "flipVertical": false },
      "style": { /* §12.4 */ },
      "animation": { /* §12.5 */ },
      "wordTimings": [ { "text": "Hello", "startFrame": 0, "endFrame": 20 }, /* ... */ ] 
    }
  ]
}
```

`textClips` is **omitted from the wire format entirely when a track has none** — the same
"omit an empty optional collection" convention `SnapshotClip.effects` already uses (§11.3), not the
"always present, even empty" convention `tracks`/`clips` use (those are structurally load-bearing;
`textClips` is a v1.2 addition with no meaning to a pre-v1.2 reader). A track that carries **only**
text clips (no ordinary video/audio clips at all — e.g. a dedicated "Captions" track) is still
emitted, with `"clips": []` and a populated `"textClips"` — `TimelineSnapshotBuilder.EmitVideoLane`
now appends a `SnapshotTrack` when *either* list is non-empty (previously: only when `clips` was).

### 12.3 Fields carried, and why each one is (or isn't) there

`SnapshotTextClip` mirrors exactly what `Compositing/TextFrameRenderer.swift` (`TextFrameRenderer.image`)
and `Compositing/FrameRenderer.swift` (`composedTextLayer`) actually read off a `.text` `Clip` at
render time — nothing more, nothing less:

- `id` — `Clip.id`, or the nest-prefixed id from §4 for a flattened clip (identical convention to
  `SnapshotClip.id`).
- `startFrame` / `durationFrames` — carried straight from `Clip` (post-flatten values for a nested
  clip, identical convention to `SnapshotClip`).
- `content` — `Clip.textContent`, verbatim. A clip whose content is empty (`null` or `""`) is
  **dropped entirely** — not emitted as an empty-content `SnapshotTextClip` — mirroring
  `CompositionBuilder`'s own `guard !(clip.textContent ?? "").isEmpty else { continue }` (present at
  *both* of its two `.text`-handling call sites, `expandNestVideo`'s child-clip loop and
  `compositorInstructions`' top-level loop).
- `opacity` — a real `{ value, keyframes }` envelope, identical shape/semantics to
  `SnapshotClip.opacity` (§11.2). This is the **one** animatable property `composedTextLayer`
  genuinely samples per frame for text (`clip.opacityAt(frame:)`, which consults `OpacityTrack`
  exactly like any other clip) — fade envelopes apply too, the same `opacityAt` call handles both.
- `blendMode` — identical convention to `SnapshotClip.blendMode` (`null` = normal/source-over).
  `FrameRenderer.composite`'s blend-mode branch reads `layer.clip.blendMode` generically for every
  layer kind, text included — text is not special-cased out of blending.
- `transform` — the text box: position/anchor **and** word-wrap width in one field, because that's
  what `TextFrameRenderer.boxRect(clip.transform, renderSize)` derives from it — the CoreText
  framesetter's wrap path is built directly from `box.width` (`layoutFrame`'s
  `CGPath(rect: CGRect(x: box.minX, y: 0, width: box.width, height: box.maxY), ...)`). There is no
  separate "wrap width" or "anchor" field in the schema because there is no separate one on the Mac
  either — `transform.width`/`height` (normalized, same units as `SnapshotClip.transform`) *is* the
  wrap width and box height; `transform.centerX`/`centerY` *is* the anchor. **Unlike
  `SnapshotClip.transform`, this is a flat object, not a `{ value, keyframes }` envelope — it is
  always static.** `TextFrameRenderer.image` reads `clip.transform` directly
  (`let box = boxRect(clip.transform, renderSize)`), never `clip.transformAt(frame:)` — so even a
  text clip that happens to carry populated `PositionTrack`/`ScaleTrack`/`RotationTrack` keyframes
  (the Mac inspector doesn't expose keyframing UI for a text clip's transform, but nothing in the
  model layer prevents one from existing on a legacy/agent-authored project) has **zero observable
  render effect** from them — carrying a `keyframes` envelope here would document a capability that
  doesn't exist. `TextLayout.naturalSize`/`.NaturalSize` (the auto-fit-box-to-content helper the UI
  uses when a caption is first typed) is **not** part of this section at all — it's a pure
  authoring-time convenience that already baked its answer into `Clip.transform` before the project
  was ever saved; the render path never calls it.
- `style` — full `TextStyle`, hand-written key-for-key (fontName, fontSize, fontScale, isBold,
  isItalic, color, alignment, shadow, background, border — see §12.4 for the font-fallback note).
- `animation` — full `TextAnimation` (preset, perWordFrames, highlight — see §12.5).
- `wordTimings` — `Clip.wordTimings` verbatim (`null` when absent), one `{ text, startFrame,
  endFrame }` triple per token, **clip-relative frames** — `WordTiming.startFrame`/`endFrame` are
  already clip-relative at rest in the Swift/C# model (`TextFrameRenderer.tokenTimings` computes
  `rel = frame - clip.startFrame` and compares directly against them), so, like every other
  clip-relative field in this schema, they're emitted with no re-basing.
- `effects` — identical shape/convention to `SnapshotClip.effects` (§11.3, omitted when empty).
  `composedTextLayer` runs `clip.effects` through the exact same `EffectRegistry.descriptor(id:)` →
  `render(...)` pipeline as any other layer, **after** rasterizing the glyphs
  (`TextFrameRenderer.image` runs first, then effects apply to that image) — a color-grade effect
  on a text clip is a real, supported thing on the Mac today.
- **Deliberately absent, unlike `SnapshotClip`:** `crop`, and the whole `volume`/fade-envelope
  bundle. `composedTextLayer` never calls `clip.cropAt(frame:)`, and none of `Clip.volume` /
  `fadeInFrames` / `fadeOutFrames` / `volumeTrack` have any render-time meaning for a `.text` clip
  (they're audio-mix concepts; text produces no audio). `SnapshotClip` carries `volumeGain` for
  every clip type "for schema uniformity" (§5) because it already existed generically before text
  entered the schema at all — `SnapshotTextClip` is a new type with no such legacy obligation, so
  it simply omits fields that would always be dead weight.

### 12.4 Font resolution happens at render time — the snapshot carries the stored name verbatim

`TextStyle.fontName` defaults to `"Helvetica-Bold"` (`Models/TextStyle.swift:8`, and independently
in its lenient-decoder fallback at `TextStyle.swift`'s custom `init(from decoder:)`) — a font that
does not exist on Windows and is not bundled. **The builder performs no substitution.** Whatever
string decoded out of the project's stored `textStyle` JSON — `"Helvetica-Bold"`, a real installed
family, a bundled caption font, or anything else, including a name that resolves to nothing on the
machine actually rendering — is written into `style.fontName` unchanged.
`TimelineSnapshotBuilder.DeserializeTextField<TextStyle>` hands `Clip.TextStyle`'s raw stored JSON
(`JsonElement`, per `Timeline.cs`'s doc comment on that property) straight to the same lenient
`TextStyleJsonConverter` the project file itself decodes with — so a missing/legacy-shaped
`textStyle` resolves to the *stored-default* `"Helvetica-Bold"` exactly as it would when the
project was opened in the editor, not to some Windows-appropriate substitute.

The Helvetica-Bold → bundled-fallback mapping (platforms/windows's own visual-parity requirement,
"map it — and any missing font name in loaded projects — deterministically to a bundled fallback so
the same project renders the same on both platforms") is **entirely a render-time concern**,
belonging to whichever component resolves `style.fontName` against the DirectWrite font
collection/custom font set at draw time (E4, native side). This keeps the snapshot itself a
faithful, lossless mirror of what's actually stored in the project — the same principle every other
section of this doc already follows (e.g. §5's `mediaPath` is "what `MediaResolver` found," not
some display-friendly transformation of it).

### 12.5 `animation`

`TextAnimation`'s three fields carry straight across:

```jsonc
"animation": {
  "preset": "wordReveal",
  "perWordFrames": 6,
  "highlight": { "r": 1.0, "g": 0.85, "b": 0.0, "a": 1.0 }
}
```

- `preset` — `TextAnimation.Preset` raw value verbatim (`"none"`, `"fadeIn"`, `"popIn"`,
  `"slideUp"`, `"typewriter"`, `"wordReveal"`, `"wordSlide"`, `"wordPop"`, `"wordCycle"`,
  `"highlightPop"`, `"highlightBlock"` — see `TextAnimation.swift`'s `Preset` enum for the
  authoritative list and each preset's `renderMode` grouping). `"none"` is a real, valid value
  here (an inactive/no-animation text clip is still a text clip) — it is **not** omitted the way a
  `null` field elsewhere in this schema might be.
- `perWordFrames` — verbatim `Int`.
- `highlight` — `TextStyle.RGBA?`; `null` when unset (`TextAnimation.highlight == nil` on the
  Swift/C# side means "use `TextAnimation.defaultHighlight`" — that default-substitution is a
  render-time concern, exactly like §12.4's font fallback; the snapshot carries `null`, not the
  resolved default color).

This section carries no per-frame evaluation logic of its own — `TextAnimator.swift`'s
`clipEntry`/`wordState` functions are pure functions of `(preset, perWordFrames, highlight,
wordTimings, frame)`, all of which are already in the snapshot (§12.3), so native has everything it
needs to reproduce them without the builder precomputing anything.

### 12.6 Compatibility

A v1/v1.1 producer (`minorVersion` absent or `1`, no track has a `textClips` key) parses and
renders identically under v1.2-aware native code once that exists — `textClips` is read as "absent
→ empty" exactly like `effects`/keyframe arrays already are (§11.4's established pattern). Today,
**before E4 implements native text parsing**, a v1.2 producer's `textClips` key is simply a JSON
object member the current `TimelineSnapshotParser::ParseTrack` never queries — `simdjson`'s `dom`
API only visits a key when something calls `element["thatKey"]`; an un-requested sibling key is
never touched, so it cannot trigger a parse error or any other observable effect. This was verified
by reading `ParseTrack`/`ParseClip` in full (`TimelineSnapshotParser.cpp`) rather than assumed: they
read `id`, `type`, `muted`, `clips` and, per clip, the v1/v1.1 field set (§5/§11) — nothing else.
**No native code changes were made or are needed for the parser to tolerate a v1.2 snapshot** — E4
adds native `textClips` parsing/rendering as new code, not as a fix to existing code that would
otherwise reject it.

One consequence worth flagging explicitly: a `SnapshotTrack` that carries text clips but zero
ordinary clips (§12.2's "dedicated Captions track" case) parses today as a **valid, entirely
empty** video track under pre-E4 native code (`"clips": []`) — the track exists in `tracks[]` but
contributes nothing to compositing, and its `textClips` are silently invisible until E4 lands. This
is the intended, `minorVersion`-gate-free degradation (same posture as Lottie in v1: a known,
tracked gap, not an error) — not a bug to fix here.
