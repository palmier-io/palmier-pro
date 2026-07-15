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
  - `keyframes` — always `null` in v1 (dB keyframe track, `Keyframe<Double>` shape, arrives with
    E3 — this is `Clip.VolumeTrack` in the Swift model).
  - **Why volume is present at all before E4.5 (audio playback) lands:** the fields are part of
    the schema now so the engine doesn't need another ABI-shape change once E4.5 starts consuming
    them — v1's native side is free to ignore this object entirely today.

## 6. Excluded clip types

- **Text** (`ClipType.Text`) — excluded entirely in v1. On the Mac, text never becomes a
  composition track either (`CompositionBuilder.build`'s `.filter { $0.mediaType != .text }`) —
  it renders through a separate Direct2D/DirectWrite text-compositing path, which is E4
  ("Text/titles") on the Windows roadmap. A text clip contributes nothing to the snapshot: no
  track, no clip entry, no `offlineMediaRefs`/`unprocessableMediaRefs` entry (it isn't a media
  reference at all).
- **Lottie** (`ClipType.Lottie`) — excluded entirely in v1. This is a genuine **divergence from
  the Mac**, not a mirror of existing Mac behavior: `CompositionBuilder` *does* composite Lottie
  clips today (baked to an alpha-video intermediate via `LottieVideoGenerator`, then treated as
  ordinary footage). The Windows ThorVG bake pipeline is E4.7 and doesn't exist yet, so v1's
  builder skips Lottie clips rather than emitting a clip the engine has no way to render. Skipped
  Lottie clips are **not** added to `offlineMediaRefs`/`unprocessableMediaRefs` — that would
  misreport a known, tracked gap as a missing-file error. A project with Lottie clips still opens
  and plays in v1 (Phase 1 requirement); the Lottie clips are simply invisible/silent until E4.7.

Both exclusions happen structurally — `RenderableClips` filters `MediaType is ClipType.Text or
ClipType.Lottie` out of a clip list before it's walked. This filter runs *inside*
`EmitVideoLane`/`EmitAudioLane` themselves, not once by their caller, specifically so every entry
point applies it identically: the top-level per-track loop AND every recursive nested-sub-track
call out of `ExpandNestVideo`/`ExpandNestAudio` (a nested child timeline's own tracks can carry
text/lottie clips too — filtering only once at the top would leak those through).

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
order** via `Utf8JsonWriter` calls in source order — no `JsonSerializer` reflection, no dictionary
iteration anywhere in the write path (there is nothing dictionary-shaped in this schema: no
`Effect.Params`, no keyframe collections — those are exactly the dictionary-shaped things v1
excludes). Same `ProjectFile` + `MediaResolver` state in ⇒ byte-identical JSON out, every time.
This is asserted directly by a golden-fixture test (`TimelineSnapshotBuilderTests`) that builds a
snapshot twice from the same inputs and compares bytes.

## 10. Golden fixtures

`platforms/windows/tests/PalmierPro.Services.Tests/Engine/Fixtures/` contains checked-in, hand-verified
example snapshot JSON the native agent can parse in its own (simdjson) tests once the timeline ABI
lands:

| File | Demonstrates |
|---|---|
| `simple-two-track.snapshot.json` | Baseline shape: one video + one audio top-level track, track/clip field layout, the `{value, keyframes}` / `volume` envelopes, `blendMode: null` |
| `nested-sequence.snapshot.json` | §4 flattening: a `.sequence` clip's child timeline (2 video sub-tracks) spliced in with remapped `startFrame`/`trimStartFrame`, nest-prefixed clip and track ids |
| `missing-media.snapshot.json` | §8: one clip whose manifest entry points at a nonexistent file — clip skipped, empty track omitted entirely, ref surfaced only via the separate (non-JSON) `OfflineMediaRefs` result |

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
