# Lottie bake pipeline — v1 (E4.7)

Normative spec for Stage E's Lottie-bake milestone (E4.7 in the Windows-port plan's roadmap:
"E4.7 Lottie bake (ThorVG → alpha intermediate, disk-cached)"). This is the contract referenced by
the plan's render-graph section: *"ThorVG rasterizes frames → FFmpeg encodes an alpha-capable
intermediate (prores_ks 4444 …) with disk cache + freeze-frame hold tail … → compositor treats it
as ordinary video."* **This document defines the contract only** — the two normative surfaces it
specifies (the native ABI additions in `native/include/palmier_engine.h` and the C# interface in
`PalmierPro.Services.Media.ILottieBakeService.cs`) are declared and land with this document; the
native `.cpp` implementations, the vendored ThorVG static library itself, `TimelineSnapshotBuilder.cs`'s
new Lottie branch, and `EngineMediaProbe.ProbeLottieAsync`'s real body do **not** ship with it — see
§16 for exactly which future agent owns each. This mirrors the precedent set by
`docs/audio-playback-v1.md` (whose ABI additions likewise landed as declarations months before their
`.cpp` bodies did) and `docs/timeline-snapshot-v1.md` (schema first, native parser support later).

## 1. Scope

In scope: the ThorVG vendoring decision; when a bake is triggered; the disk cache key/layout; the
size/fps/hold-tail parameters a bake uses; the pixel format contract between ThorVG's rasterizer and
FFmpeg's encoder; the native ABI surface; the C# `ILottieBakeService` interface; how
`TimelineSnapshotBuilder` will consume it once implemented; and the closely-related
`EngineMediaProbe.ProbeLottieAsync` metadata-probe stub this same ThorVG dependency also closes.

Out of scope (named explicitly, not silently dropped): rendering a Lottie asset's *own* opacity/
transform/effects as a group over its baked content — irrelevant here, a baked Lottie clip becomes an
ordinary `SnapshotClip` and gets the same opacity/transform/effects handling every other video clip
already has, with nothing Lottie-specific left once §10 lands. Lottie *expressions* (JS-driven
animated properties — ThorVG's optional `jerryscript`-backed feature) — §3 excludes the dependency
that would make them work; an expression-driven property renders however ThorVG's own no-expressions
fallback resolves it (typically its static/default value), a known, documented gap, not a bug.
Embedded Lottie *audio* layers (ThorVG's `LottieAudioResolver`, §3) — the Mac's own
`LottieVideoGenerator` doesn't play Lottie audio either (it renders frames only, via
`view.layer?.render(in:)` — `Preview/LottieVideoGenerator.swift:164`), so this is parity, not a new
gap. A media-panel thumbnail for a `.json`/`.lottie` asset (distinct from the timeline video bake) —
named in §11 as a related-but-separate need, not delivered here.

## 2. Mac architecture recap (source of truth)

`Preview/LottieVideoGenerator.swift` + the Lottie branch of `Preview/CompositionBuilder.swift`
(`loadSource`, lines 353-364) are the ported source of truth. The facts this document carries over
verbatim:

- **Cache location:** `DiskCache(named: "LottieVideos")` (`LottieVideoGenerator.swift:9`) — a named
  subdirectory of the app's cache root, exactly the same shape as every other Mac disk cache.
- **Cache key (Mac):** `"\(mediaRef)_\(Int(target.width))x\(Int(target.height)).mov"`
  (`LottieVideoGenerator.swift:80`) — asset id + baked pixel size, nothing else. **Windows
  deliberately does not copy this key verbatim** — see §5 for why content hash replaces `mediaRef`.
- **Trigger point:** lazy, per-composition-build, inside `CompositionBuilder.loadSource`
  (`CompositionBuilder.swift:353-364`) — `lottieVideo(for:mediaRef:size:)` is called exactly when a
  timeline being composited references a Lottie clip, not at import time. `LottieVideoGenerator.inspect`
  (a separate, lighter call — metadata + one thumbnail frame) is what runs at import, for the media
  library — see §11.
- **Size resolution:** `resolveSourceSize(clip.mediaRef) ?? renderSize` (`CompositionBuilder.swift:354`).
  `resolveSourceSize` is backed by `MediaAsset.sourceWidth`/`sourceHeight` when both are populated and
  `> 0` (`VideoEngine.swift:165-170`'s `assetSizes` dictionary build), falling back to the timeline's
  own render size otherwise. Ported to Windows in §6.
- **Freeze-frame hold tail:** `holdTailSeconds = 1800` (`LottieVideoGenerator.swift:15`) — **not** every
  frame repeated for 30 minutes; `writeVideo`'s `schedule` array (`LottieVideoGenerator.swift:217-220`)
  appends exactly **one** extra sample, the animation's last frame, at
  `max(holdTailSeconds, duration + 1)` seconds. QuickTime/ProRes hold-displays a sample until the next
  one arrives (or EOF), so a single far-future timestamp is all a freeze-frame hold needs — ported
  verbatim in §6/§8.
- **Encoder clamp:** `maxEncoderDimension = 4096` (longest side, `LottieVideoGenerator.swift:12`) and
  `even(_:)` rounds each dimension down to the nearest even value (`LottieVideoGenerator.swift:276-278`)
  — ProRes 4:4:4:4 requires even width/height. Ported verbatim in §6/§8.
- **Output codec:** `AVVideoCodecType.proRes4444`, `kCVPixelFormatType_32BGRA`,
  `kCVPixelBufferCGBitmapContextCompatibilityKey` (`LottieVideoGenerator.swift:196-210`) — premultiplied
  BGRA rasterized straight into the pixel buffer the encoder reads from, no intermediate copy.
- **Atomicity:** `writeVideo` writes to `.writing-<uuid>.mov` in the same directory, `defer`-removes it
  unconditionally, and only `moveItem`s it to the real cache path on success — with a check right before
  the move that re-reads "does the real path already exist now" (a second concurrent bake of the same
  key winning the race is tolerated silently: `guard !fm.fileExists(atPath: outputURL.path) else {
  return }`, `LottieVideoGenerator.swift:238-244`). Ported in §5/§13.
- **Detection (already ported, not part of this document):** `.lottie`/`.json` sniffing
  (`LottieVideoGenerator.isLottie`) and `ClipType.Lottie` routing already exist on Windows — confirmed
  by grep across `TimelineSnapshotBuilder.cs`, `MediaImportDialogService.cs`,
  `TimelineEditorViewModel.Tracks.cs`, `MediaAsset.cs`, `ClipType.cs`. This document starts from "a clip
  is already known to be `ClipType.Lottie`," nothing upstream of that changes.

## 3. ThorVG vendoring decision

**Pin: ThorVG v1.0.7** (tagged 2026-07-02, https://github.com/thorvg/thorvg, MIT license — confirmed
in its own `meson.build`: `license : 'MIT'`). A specific tagged release, not `main`, matching this
repo's existing pin discipline (FFmpeg's own `THIRD_PARTY_NOTICES.md` entry: *"a versioned
release-branch build rather than the rolling `master-latest` tag, so the pin is reproducible"*).

**Decision: static-lib vcxproj, not amalgamation.** The two options the plan named:

| Option | Verdict |
|---|---|
| Amalgamated single header/source (simdjson's pattern) | **Rejected** |
| Static-lib `.vcxproj`, vendoring ThorVG's own source tree | **Chosen** |

Why amalgamation is rejected, concretely (not "it wasn't tried" — verified against the actual
upstream tree via `gh api repos/thorvg/thorvg/contents/...`):

- **ThorVG ships no official amalgamation.** simdjson's `singleheader/simdjson.h` +
  `singleheader/simdjson.cpp` is a build artifact simdjson's own CI produces and publishes — we just
  download it (`THIRD_PARTY_NOTICES.md`'s simdjson entry). ThorVG publishes no equivalent; its only
  build system is Meson (`project('thorvg', 'cpp', ...)`, `src/meson.build`), and Meson's own
  `source_file` lists (e.g. `src/loaders/lottie/meson.build`) are the *only* upstream-maintained
  manifest of which files belong together.
- **The engine is too large and too actively factored for a hand-rolled amalgamation to stay safe.**
  `src/renderer/` (14 `.cpp` files: `tvgAnimation`, `tvgCanvas`, `tvgPicture`, `tvgScene`, `tvgShape`,
  `tvgPaint`, `tvgFill`, `tvgText`, `tvgLoaderMgr`, `tvgTaskScheduler`, `tvgInitializer`, `tvgAccessor`,
  `tvgSaver`) + `src/renderer/cpu_engine/` (11 more, the software rasterizer) + `src/loaders/lottie/`
  (9 more, the Lottie parser/builder/interpolator) is ~35 translation units with genuine internal
  header dependencies (`tvgSwCommon.h`, `tvgLottieCommon.h`, etc.) that a concatenation script would
  have to reconcile (include-guard collisions, static/anonymous-namespace collisions across
  concatenated files) — simdjson's amalgamation works because simdjson's *own* tooling does exactly
  this reconciliation and ships the result; nothing does that for ThorVG, and writing it ourselves is
  real, ongoing maintenance (every upstream version bump would need re-verification that the
  concatenation still behaves identically to the modular build) for a project that isn't small
  (signalsmith-stretch, by contrast, genuinely IS a small, stable, header-only library where vendoring
  a handful of files verbatim carries none of this risk — the `THIRD_PARTY_NOTICES.md` entries for
  simdjson and signalsmith-stretch are each the *right* choice for *that* dependency's actual shape;
  ThorVG's shape is neither).
- **A static lib matches this repo's own established build discipline for in-process native
  dependencies.** `PalmierEngine.vcxproj` itself is a hand-authored MSBuild project (not CMake, not
  Meson) per `platforms/windows/AGENTS.md`'s "native engine via `msbuild`, not `dotnet`" rule — a
  sibling `ThorVG.vcxproj` static-lib project, listing exactly the vendored `.cpp` files as MSBuild
  `<ClCompile>` items (the direct MSBuild analogue of Meson's `source_file` lists — same information,
  different build system, both hand-auditable against upstream's own manifest), is the smallest
  possible step outside this repo's existing tooling. It also keeps every ThorVG-internal header
  (`tvgCommon.h`, `tvgSwCommon.h`, …) private to that one static lib — `PalmierEngine.vcxproj` links
  against it and includes only the two public umbrella headers (`inc/thorvg.h`,
  `src/loaders/lottie/thorvg_lottie.h`), mirroring how `MediaSource.h/.cpp` already encapsulates
  FFmpeg's C API rather than leaking `libav*` headers repo-wide.
- **No GPU engines, no extra vendored dependencies.** ThorVG's `gl_engine`/`wg_engine` (OpenGL/WebGPU
  rasterizers) are excluded — the bake path is CPU-only, rasterizing to a plain memory buffer for
  FFmpeg to encode (mirrors the Mac's own CPU-side `CGContext`/`CALayer.render(in:)` bake path exactly
  — there's no GPU involved in `LottieVideoGenerator` either). `jerryscript` (ThorVG's optional
  JS-expression engine, a full embedded JS runtime) is excluded — `lottie_exp` is Meson-gated off by
  default and `tvgLottieExpressions.cpp` degrades to a no-op without it (verified: the loader's
  `source_file` list unconditionally includes `tvgLottieExpressions.cpp`, but only `if lottie_exp:
  subdir('jerryscript')` pulls in the JS engine itself — the expressions file is written to tolerate
  its absence). `src/loaders/svg/` is excluded (this pipeline never opens a standalone SVG). Raster
  image loaders (`src/loaders/png`, `src/loaders/jpg` — ThorVG's own bundled, dependency-free decoders,
  not wrappers around system libpng/libjpeg) are a **named v1 gap**: embedded base64 image data inside
  a Lottie JSON is handled by the always-vendored `tvg::b64Decode` (`src/common/tvgCompressor.h`) with
  no extra loader needed, but a Lottie asset referencing an *external* raster file (rare in
  single-file `.json` exports, more common inside a `.lottie` package's `assets/` — see §12) renders
  as a transparent hole in v1 until `png`/`jpg` are vendored too — a follow-up, not a blocker (most
  authored motion-graphics Lotties are vector-only).
- **Vendored file set (concrete, MSBuild-source-list-ready):** `src/common/*.{h,cpp}`,
  `src/renderer/*.{h,cpp}` (excluding `tvgSaver.cpp`/`.h` — no save/export path needed),
  `src/renderer/cpu_engine/*.{h,cpp}`, `src/loaders/lottie/*.{h,cpp}` (excluding the `jerryscript/`
  and `rapidjson/` subdirectories' own build — `rapidjson` is header-only and pulled in via the lottie
  loader's own `#include`s, so it's vendored as headers-only alongside it, exactly like
  signalsmith-stretch's own "vendor the subset actually `#include`d" precedent), plus the two public
  umbrella headers (`inc/thorvg.h`, `src/loaders/lottie/thorvg_lottie.h`). All under
  `native/third_party/thorvg/`, unmodified from the v1.0.7 tag, with ThorVG's own `LICENSE` file
  alongside (mirrors `native/third_party/signalsmith-stretch/`'s layout exactly).

`THIRD_PARTY_NOTICES.md`'s ThorVG entry is updated by this document to record the pin and this
decision (status: decision landed, files not yet vendored — see §16).

## 4. Bake trigger points

Exactly one trigger, mirroring §2's Mac precedent precisely — **no eager/import-time trigger is
added** (the Mac doesn't have one either; `inspect` at import is metadata+thumbnail only, §11):

- **`TimelineSnapshotBuilder.Build`**, when it reaches a clip with `MediaType == ClipType.Lottie`
  (today: unconditionally skipped, `TimelineSnapshotBuilder.cs:216-219`, `// v1/v1.1 gap, unchanged by
  v1.2 — see docs §6` in `docs/timeline-snapshot-v1.md`). Once this document's contract is implemented
  (§16), that branch becomes: compute the clip's `LottieBakeRequest` (§5's key inputs — resolved source
  path, target size per §6), call `ILottieBakeService.TryGetCachedPath(request)`:
  - **Cached already** → emit an ordinary `SnapshotClip` (`Type = Video`, `MediaPath` = the cached
    `.mov` path) exactly like any other video clip. Zero Lottie-specific code left downstream of this
    point — this is the plan's "compositor then treats it as ordinary video" made concrete.
  - **Not cached** → call `ILottieBakeService.BakeAsync(request)` (a no-op if already in flight for the
    identical key — dedup lives in the service, §9) and skip the clip from the snapshot for *this*
    build (§10 has the exact "why skip, not offline" reasoning). The builder additionally reports the
    key in a new `TimelineSnapshotBuildResult.PendingLottieBakes` set (§10) so a caller can show
    "Baking…" instead of silence.
- **Every subsequent rebuild** (a structural edit, a timeline re-open, an app relaunch with a
  since-completed cache entry) re-checks `TryGetCachedPath` fresh — there is no separate "was this
  already requested" state inside the builder itself; `ILottieBakeService` alone owns bake lifecycle
  (in-flight dedup, completed-cache lookup). A relaunch that finds a cold cache re-triggers exactly one
  bake per distinct key, same as a first-ever open would.

## 5. Cache key & disk layout

**Directory:** `LottieVideos` under the app's cache root (`PalmierPro.Services.Project.AppPaths.
CacheDirectory` — the same root `DiskCache` already resolves against, see `DiskCache.cs:18`), via
`new DiskCache("LottieVideos")` — the identical directory name the Mac uses
(`LottieVideoGenerator.swift:9`), reusing the existing `PalmierPro.Services.Media.DiskCache` helper
class exactly as `MediaVisualCache` already does (`MediaVisualCache.cs:76`).

**Key: `{contentHash}_{width}x{height}_v{bakeVersion}`** — three components, all required, deliberately
**not** the Mac's `{mediaRef}_{width}x{height}` (§2):

1. **`contentHash`** — SHA-256 of the *source file's own bytes* (the `.json`/`.lottie` as it sits on
   disk at `LottieBakeRequest.SourcePath`), truncated to 16 hex chars, in the exact same style as
   `DiskCache.SizeMtimeKey`'s own hashing (`DiskCache.cs:26-36`: `SHA256.HashData` → `Convert.
   ToHexStringLower(hash.AsSpan(0, 16))`) — **but hashing content, not `(path, length, mtime)`.** This
   is a deliberate divergence from `DiskCache.SizeMtimeKey`, not an oversight, for a reason specific to
   this cache: Lottie source files are typically small (a `.json` under a few hundred KB is the common
   case — the Mac's own `isLottie` sniff only reads the first `jsonSniffByteLimit = 256 * 1024` bytes
   expecting the signature keys near the top, `LottieVideoGenerator.swift:16`), so hashing the whole
   file is cheap, and content identity is strictly more correct than `(size, mtime)` identity for this
   asset class: a project package copy/move, a `git checkout` that resets mtimes, or a user re-saving
   an *unchanged* Lottie export from their design tool can all touch mtime without touching a single
   byte — `SizeMtimeKey` would spuriously invalidate (a correctness-neutral but wasteful re-bake);
   content-hash survives all three untouched. The implementer adds this as a new
   `DiskCache.ContentHashKey(path)` static method, sibling to the existing `SizeMtimeKey`, same
   hex-16 convention, same `File.Exists` guard (`DiskCache.cs`'s existing "no key rather than throwing"
   discipline) — not part of this document's own file changes (§16).
2. **`{width}x{height}`** — the target pixel size (§6), **after** even-rounding — mirrors the Mac's
   filename convention exactly (`LottieVideoGenerator.swift:80`), so two different placements of the
   same Lottie asset at two different composited sizes cache independently, exactly like the Mac.
3. **`v{bakeVersion}`** — an integer pipeline-version constant (starts at `1`), owned by the concrete
   `LottieBakeService` implementation (not the interface — it's an implementation detail of the cache
   key algorithm, §9). Bumped whenever a change could alter previously-cached bytes for an unchanged
   input: a ThorVG version bump that changes rasterization output, an encoder-settings change (e.g. a
   different ProRes profile), or a bug fix in the bake logic itself. Mirrors
   `TimelineSnapshotBuilder.SchemaMinorVersion`'s own bump discipline (`docs/timeline-snapshot-v1.md`
   §11.1) — a stale cache entry from an older pipeline version is simply a cache miss under the new
   version's key, never a wrong-content cache hit.

**Filename:** `{key}.mov` via `DiskCache.PathFor(key, ".mov")` — no separate sidecar (unlike
`MediaVisualCache`'s sprite-sheet + JSON-sidecar pair, §6's parameters are fully recoverable from the
filename's own `{width}x{height}` plus the source file re-hashed on demand, so nothing else needs
persisting alongside the video).

**Atomicity — ported from §2, one level up (C#, not native):** the concrete `LottieBakeService`
opens/writes to a temp path (`LottieVideos\.baking-{uuid}.mov`, same naming convention as the Mac's
`.writing-<uuid>.mov`) via `PE_BakeLottieVideo` (§8 — which itself is a single call producing a
complete file, so the "partial-write" risk this guards against is process-crash-mid-bake, not a
partial hand-off between two native calls), then does the same "does the real cache path already
exist now" recheck before `File.Move` that the Mac's `writeVideo` does
(`LottieVideoGenerator.swift:238-244`) — a second concurrent bake of the identical key racing to
completion is tolerated silently (first mover wins, second mover's temp file is deleted, not an error).
`ILottieBakeService.BakeAsync`'s own in-flight dedup (§9) makes the race rare in practice (two
`TimelineSnapshotBuilder.Build` calls for the same key while a bake is running only ever result in one
in-flight bake), but the filesystem-level recheck is kept anyway as defense-in-depth, exactly mirroring
why the Mac keeps its own recheck despite `LottieVideoGenerator` having no equivalent in-flight guard
at all.

## 6. Bake parameters

- **Target size:** `MediaAsset.SourceWidth`/`SourceHeight` for the clip's `MediaRef`, when both are
  populated and `> 0` (looked up via `TimelineSnapshotBuilder`'s existing `MediaResolver.Entry(mediaRef)`
  — `MediaResolver.cs:91` — which already exposes `MediaManifestEntry.SourceWidth`/`SourceHeight`, the
  exact same fields `MediaAsset.FromManifestEntry` populates, `MediaAsset.cs:116-117`), else the
  timeline's own `OutputWidth`/`OutputHeight` (`TimelineSnapshot`'s existing fields) — a direct, 1:1
  port of `resolveSourceSize(clip.mediaRef) ?? renderSize` (§2). **Before §11 lands,
  `MediaAsset.SourceWidth`/`SourceHeight` are always null for a `ClipType.Lottie` asset** (
  `EngineMediaProbe.ProbeLottieAsync` unconditionally returns `null` today), so every bake falls back to
  the timeline's render size until the metadata probe is real — safe (never wrong, only occasionally
  not the asset's own preferred size), self-correcting once §11 lands, not a bug to special-case around
  here.
- **Even-dimension rounding:** `PE_BakeLottieVideo` rounds `targetWidth`/`targetHeight` down to even
  itself (§8) — callers pass the unrounded size §6 computes.
- **Max dimension clamp:** 4096 px longest side (§2's `maxEncoderDimension`) — owned by the same native
  rounding step inside `PE_BakeLottieVideo`, not duplicated in C#.
- **Frame rate / frame count:** read from the opened ThorVG animation itself (`tvg::Animation`'s
  `totalFrame()`/the Lottie composition's own authored frame rate — ThorVG's `LottieLoader::frameRate`/
  `frameCnt`, confirmed present on the vendored `LottieLoader` type, §3), never supplied by the caller —
  mirrors the Mac reading `animation.framerate`/`animation.endFrame - animation.startFrame`
  (`LottieVideoGenerator.swift:52-58`'s `metadata(for:)`) directly off the loaded animation, not off
  any caller-supplied value.
- **Hold-tail:** `holdTailSeconds` is a caller-supplied parameter to `PE_BakeLottieVideo` (§8), not a
  native constant — the concrete `LottieBakeService` passes `1800.0`, matching §2's Mac constant
  verbatim (kept as a parameter rather than hardcoded natively for the same "reserve the shape, pin the
  value at the call site" discipline this ABI already uses elsewhere, e.g. `PE_TimelineSetRate` accepting
  a general `double rate` even though Phase 1 only ever passes `{0.0, 1.0}` — `docs/audio-playback-v1.md`
  §4).

## 7. Pixel format & alpha

**Premultiplied BGRA32 throughout, zero conversion passes.** ThorVG's `tvg::SwCanvas::ARGB8888`
colorspace (the non-`S`-suffixed variant — `ARGB8888S` is straight/un-premultiplied, confirmed against
ThorVG's own colorspace docs, introduced in v0.12) is:

- **Premultiplied** — matches this engine's canonical working format exactly (the plan's "Canonical
  working format: … storing gamma-encoded, premultiplied-alpha RGBA" — no `AlphaVideoNormalizer`-style
  straight-to-premultiplied conversion pass is needed for a Lottie bake specifically, unlike an
  arbitrary imported alpha video source, which still needs that normalizer for straight-alpha sources).
- **Byte-identical to `PE_FrameBuffer`'s existing BGRA32 convention on this little-endian target** — a
  32-bit word described as "alpha, red, green, blue" channel order (ThorVG's own docs) is, read as four
  ascending memory bytes on a little-endian machine, blue-green-red-alpha — i.e. BGRA byte order,
  exactly what `PE_FrameBuffer`/`PE_ExtractThumbnails`/every other frame buffer in this ABI already
  uses. `PE_EncodeAlphaVideoPushFrame`'s `bgraData` parameter is ThorVG's raw `SwCanvas` target buffer,
  passed straight through — no channel swizzle, no premultiply pass, between rasterization and encode.

**Encoder side:** `prores_ks` at the 4444 profile (FFmpeg's alpha-capable ProRes profile, matching the
Mac's `AVVideoCodecType.proRes4444` exactly) — the concrete implementer configures `AVCodecContext` with
`pix_fmt = AV_PIX_FMT_YUVA444P10LE` (ProRes 4444's actual coded format; the BGRA→YUVA conversion this
implies is FFmpeg/`prores_ks`'s own internal concern, the same way it already is for the Mac's
`AVAssetWriter`/ProRes encoder — this document's ABI contract stops at "premultiplied BGRA32 frames in,"
matching the plan's own phrasing verbatim) with `alpha_bits = 16` (ProRes 4444's alpha channel).

## 8. Native ABI additions

Declared in `native/include/palmier_engine.h` (the header is the source of truth if this section and
the header ever drift — reproduced here for reference):

```c
typedef struct PE_AlphaEncoder* PE_AlphaEncoderHandle;

PALMIER_API int32_t PE_EncodeAlphaVideoOpen(PE_SessionHandle session, const char* utf8OutputPath, int32_t width, int32_t height, PE_AlphaEncoderHandle* outEncoder);
PALMIER_API int32_t PE_EncodeAlphaVideoPushFrame(PE_AlphaEncoderHandle encoder, const uint8_t* bgraData, int32_t strideBytes, double presentationSeconds);
PALMIER_API int32_t PE_EncodeAlphaVideoClose(PE_AlphaEncoderHandle encoder);
PALMIER_API int32_t PE_EncodeAlphaVideoAbort(PE_AlphaEncoderHandle encoder);

typedef void (*PE_BakeProgressCallback)(void* userCtx, int32_t framesDone, int32_t framesTotal);
PALMIER_API int32_t PE_BakeLottieVideo(
    PE_SessionHandle session,
    const char* utf8LottiePath,
    int32_t targetWidth,
    int32_t targetHeight,
    double holdTailSeconds,
    const char* utf8OutputPath,
    PE_BakeProgressCallback callback,
    void* userCtx,
    const int32_t* cancelFlag);

struct PE_LottieInfo { double durationSeconds; double width; double height; double frameRate; };
PALMIER_API int32_t PE_ProbeLottieMetadata(PE_SessionHandle session, const char* utf8LottiePath, PE_LottieInfo* outInfo);
```

**Why a streaming `Open`/`PushFrame`/`Close`/`Abort` quartet rather than one call taking an array of
frames** (the literal task naming was singular, "`PE_EncodeAlphaVideo`: BGRA frames in → prores_ks 4444
.mov out"): a single call holding every frame resident in memory doesn't scale — even at a modest 1080p
bake, a few hundred frames (a realistic count for a several-second motion-graphics loop) at
`1920×1080×4` bytes is comfortably under a gigabyte, but nothing in this contract bounds Lottie source
duration or the 4096px clamp's actual footprint tightly enough to promise that in general, and this
ABI's own established convention is to never buffer a whole video's worth of frames in one call (the
export pipeline's own "staging-texture ring readback," never "encode the whole timeline into one
buffer," is the same principle). A push-per-frame shape also naturally supports mid-bake cancellation
(checked once per `PE_BakeLottieVideo` frame iteration, §8's `cancelFlag`) and progress reporting
(`PE_BakeProgressCallback`, fired once per frame) without any extra bookkeeping — the four functions
together ARE the "`PE_EncodeAlphaVideo`" primitive the task named, shaped the way this codebase already
shapes every other multi-frame native operation.

**Why `PE_EncodeAlphaVideo*` is decoupled from `PE_BakeLottieVideo` rather than folded invisibly inside
it:** independent testability. `PE_EncodeAlphaVideo*` can be exercised with synthetic test-pattern
frames (no ThorVG, no real Lottie file) and its output validated structurally via `ffprobe` (§14) — the
same "headless golden hook, testable in isolation from the full async/live pipeline" pattern this ABI
already established for `PE_TimelineRenderAudioRange`/`PE_TimelineRenderScrubGrain` (decoupled from the
full XAudio2 playback path) and `PE_RenderFrameToFile`/`PE_TimelineRenderFrameToFile` (decoupled from
the swap-chain/present loop). `PE_BakeLottieVideo` is the real, ThorVG-driven orchestration entry point
`ILottieBakeService.BakeAsync` calls (§9) — it uses `PE_EncodeAlphaVideo*` internally (a plain C++
function call, not a re-entrant ABI round-trip) but is declared separately so both halves are
independently verifiable.

**Why `PE_ProbeLottieMetadata` is included even though the task named only the encode-helper ABI:** it
closes an already-visible stub this same ThorVG dependency exists to fill (§11) — `EngineMediaProbe.
ProbeLottieAsync` has been shipping since Stage B/E2 with the literal comment *"Lottie inspection isn't
implemented until Stage E's ThorVG bake lands"* (`EngineMediaProbe.cs:9`). Leaving it undeclared here
would mean a second, near-identical "open this Lottie file with ThorVG" ABI addition lands in a later
document instead of this one — cheaper to specify once, alongside the bake ABI that already needs the
exact same ThorVG open call internally.

## 9. C# `ILottieBakeService`

Declared in `PalmierPro.Services.Media.ILottieBakeService.cs` (full XML doc comments there; summarized
here):

| Member | Kind | Notes |
|---|---|---|
| `LottieBakeRequest(string MediaRef, string SourcePath, int Width, int Height)` | record | One bake's full identity — `SourcePath` is already resolved (via `MediaResolver`), not a raw asset id. |
| `LottieBakeStatus` | enum | `NotStarted \| InProgress \| Completed \| Failed`. |
| `string? TryGetCachedPath(LottieBakeRequest request)` | method | Non-blocking cache probe (§5's key). Never triggers a bake. |
| `void BakeAsync(LottieBakeRequest request, CancellationToken ct = default)` | method | Fire-and-forget, mirrors `MediaVisualCache.GenerateVideoThumbnails`'s in-flight-dedup pattern (`MediaVisualCache.cs:124-134`) — dedup keys off the full §5 key (content hash + size), not `MediaRef` alone. |
| `LottieBakeStatus StatusFor(string mediaRef, int width, int height)` | method | Synchronous, locally-tracked — same convention as `IVideoEngine.IsPlaying`. |
| `event EventHandler<LottieBakeStatusChangedEventArgs>? StatusChanged` | event | Fires on every status transition; `TimelineSnapshotBuilder`'s caller reacts to `Completed` (§10). |

`LottieBakeStatusChangedEventArgs` carries `(MediaRef, Width, Height, Status, OutputPath, ErrorMessage)`
— `OutputPath` populated only on `Completed`, `ErrorMessage` only on `Failed`.

**Namespace placement:** `PalmierPro.Services.Media`, not `.Engine`, despite `TimelineSnapshotBuilder`
(in `.Engine`) being its primary caller — it's a media-derivative cache, the same conceptual family as
`MediaVisualCache`/`MissingMediaService` (both already in `.Media`), not an engine/timeline concept
itself. Mirrors how `MissingMediaService` already lives in `.Media` despite being consumed by
document/VM layers outside it.

**Concrete implementation (`LottieBakeService.cs`) is not part of this document's deliverables** — an
interface with no implementer still compiles; nothing in the current solution references
`ILottieBakeService` yet, so adding it doesn't force a stub the way adding a member to the
already-implemented `IVideoEngine` did for `docs/audio-playback-v1.md` (§16 assigns the concrete class).

## 10. Snapshot integration

`TimelineSnapshotBuilder`'s Lottie branch (currently `TimelineSnapshotBuilder.cs:216-219`, an
unconditional `continue`) becomes, once implemented:

```csharp
if (clip.MediaType == ClipType.Lottie)
{
    string? sourcePath = ctx.MediaResolver.ResolveUrl(clip.MediaRef);
    if (sourcePath is null)
    {
        ctx.OfflineMediaRefs.Add(clip.MediaRef);   // genuinely missing file — existing semantics, unchanged
        continue;
    }
    var (w, h) = ResolveLottieBakeSize(clip.MediaRef, ctx);   // §6
    var request = new LottieBakeRequest(clip.MediaRef, sourcePath, w, h);
    if (lottieBakeService.TryGetCachedPath(request) is { } cachedPath)
    {
        // emit an ordinary SnapshotClip, Type = Video, MediaPath = cachedPath — falls straight
        // into the same code path a real video clip already takes below this branch.
    }
    else
    {
        lottieBakeService.BakeAsync(request);
        ctx.PendingLottieBakes.Add(clip.MediaRef);
        continue;   // not yet renderable this build — see the "why skip" note below
    }
}
```

**`TimelineSnapshotBuildResult` gains a new field:** `TimelineSnapshotBuildResult(TimelineSnapshot
Snapshot, IReadOnlySet<string> OfflineMediaRefs, IReadOnlySet<string> PendingLottieBakes)` (currently a
two-field record, `TimelineSnapshotBuilder.cs:106`) — additive, mirrors exactly how
`docs/timeline-snapshot-v1.md`'s own schema additions (§11/§12 there) stayed additive across minor
versions.

**Why "skip the clip, report a separate pending set" and NOT "add to `OfflineMediaRefs`"** (the literal
brief said "marks it offline while baking" — this is the precise, non-conflicting reading of that
phrase): `docs/timeline-snapshot-v1.md` §6 already establishes, deliberately, that a Lottie clip must
**never** land in `OfflineMediaRefs`/`UnprocessableMediaRefs` for the "not renderable yet" case —
*"Skipped Lottie clips are not added to offlineMediaRefs/unprocessableMediaRefs — that would misreport a
known, tracked gap as a missing-file error."* A clip mid-bake is exactly that same "known, tracked gap"
category, not a missing- or corrupt-file error, so overloading `OfflineMediaRefs` for it would directly
contradict an already-established, deliberate design decision in this codebase. **The observable
behavior the brief actually wants — the clip renders as absent while its bake is pending — is achieved
by the existing "skip the clip from the snapshot" mechanism alone** (unchanged from today's behavior,
in fact — a not-yet-baked Lottie clip contributes nothing to `tracks[]`, identical to how EVERY Lottie
clip behaves before this document's contract is implemented at all). `PendingLottieBakes` is the new,
honest, additive signal: a distinct set a future UI can use to show "Baking…" instead of nothing, without
lying about *why* the clip isn't rendering by conflating it with a real offline-media error.

**Rebuild trigger on completion:** whichever component owns the open `ProjectDocument`/timeline VMs
subscribes to `ILottieBakeService.StatusChanged` and, on `Completed` for a `MediaRef` any currently-open
timeline references, calls `IVideoEngine.UpdateTimelineAsync` for that timeline (a newly-baked
`mediaPath` is a new entry in the media set — a structural change per the Rebuild-vs-RefreshParams split,
`docs/timeline-snapshot-v1.md`'s own framing, and `palmier_engine.h`'s `PE_TimelineRefreshParams` doc
comment: *"A media-set change is a structural rebuild and must go through `PE_UpdateTimeline` instead"*).
**Not part of this document's own deliverables** — the exact subscriber (a `ProjectDocument` method? a
dedicated coordinator?) is a UI/document-layer wiring decision for whichever agent implements §16's `ui`
slice, mechanical once this contract exists.

## 11. Metadata probe

`PalmierPro.Services.Media.EngineMediaProbe.ProbeLottieAsync` (`EngineMediaProbe.cs:37`, currently
`Task.FromResult<LottieProbeResult?>(null)` unconditionally) becomes, once implemented:

```csharp
public async Task<LottieProbeResult?> ProbeLottieAsync(string path)
{
    PE_LottieInfo? info = /* PE_ProbeLottieMetadata via session, §8 */;
    if (info is null) return null;
    return new LottieProbeResult { Duration = info.durationSeconds, Width = info.width, Height = info.height, FrameRate = info.frameRate };
}
```

`LottieProbeResult` already exists (`MediaProbe.cs:39-45`) and already flows into
`MediaAsset.LoadMetadataAsync`'s existing `ClipType.Lottie` branch (`MediaAsset.cs:220-231`) — this is a
body-only change behind an already-shaped, already-consumed seam, not a new contract. This is the call
that, once real, makes §6's `MediaAsset.SourceWidth`/`SourceHeight` fallback stop being "always null for
Lottie."

**Explicitly not delivered here:** a media-panel thumbnail for a Lottie asset (the Mac's `inspect`'s
other half, `LottieVideoGenerator.swift:63-75`, which additionally renders one frame to a `CGImage`).
`PE_ExtractThumbnails` is shaped around an already-decodable `PE_MediaHandle`
(`PE_OpenMedia`→`PE_ExtractThumbnails`), which a raw `.json`/`.lottie` file is not — giving Lottie assets
a media-panel thumbnail needs either a distinct small ABI addition (a `PE_RenderLottieFrameToFile`-style
call, mirroring `PE_RenderFrameToFile`'s existing headless-PNG shape) or routing the *baked* video
through the existing thumbnail path after the fact. Left as a named, scoped-out follow-up (§16) — a
Lottie asset in the media library shows its generic type icon until this lands, not a broken/missing
tile.

## 12. `.lottie` (dotLottie) handling

**Decision: unzip C#-side; native only ever opens a plain-JSON path.** Verified against the vendored
dependency itself (§3): ThorVG's `LottieAnimation`/`LottieLoader` API surface (the public
`thorvg_lottie.h`, and `LottieLoader::open(const char* path, ...)`) is JSON-in, with no dotLottie
container awareness anywhere in the vendored file set (no zip/inflate helper — `src/common/
tvgCompressor.h` contains only `b64Decode`/`djb2Encode`, nothing decompression-related). A `.lottie` file
is a zip archive per the dotLottie spec (`manifest.json` + `animations/*.json` + an `assets/` directory)
— exactly what the Mac's own `DotLottieFile.loadedFrom` unzips itself, entirely inside `lottie-ios`,
before ThorVG (which the Mac doesn't use at all) ever enters the picture.

Rather than vendor a *second* third-party dependency (a zip/inflate library) into native just to teach
ThorVG about a container format it doesn't natively understand, the `LottieBakeService` implementation
(C#) uses `System.IO.Compression.ZipFile` (already in the .NET BCL, zero new dependency) to:

1. Open the `.lottie` as a zip archive.
2. Read `manifest.json`, take its first (or manifest-designated default) `animations[].id`.
3. Extract `animations/{id}.json` **and** the whole `assets/` directory (so any *external* image asset
   the animation JSON references by relative path — §3's named v1 gap — still resolves relative to
   where it's extracted, even though rendering it is deferred) to a temp directory under the same cache
   root as §5.
4. Pass the extracted plain-JSON path to `PE_BakeLottieVideo`/`PE_ProbeLottieMetadata` — from here on,
   native never knows the source was ever a `.lottie`.

This mirrors this codebase's own established division of labor (`docs/timeline-snapshot-v1.md`'s
opening line: *"C# flattens and resolves everything media/nesting/multicam-related ahead of time;
native never sees a … unresolved asset reference"*) — applied here to container format instead of
project structure, but the same principle: resolve on the C# side, hand native something simple.

**§5's content-hash key still hashes the original `.lottie` file's bytes** (the zip container as
authored), not the extracted JSON — the extraction is a pure implementation detail of *how* the bake
happens, not part of the asset's identity.

## 13. Lifecycle, cancellation, cleanup

- **App-quit mid-bake:** `PE_BakeLottieVideo` runs synchronously on a background `Task` (§8) — a process
  exit mid-call simply stops mid-write, exactly like an unclean Mac quit mid-`writeVideo` would; the
  next launch finds an orphaned `.baking-{uuid}.mov` temp file (§5), never the real cache filename
  (which only ever gets a completed file `File.Move`d onto it) — safe to sweep unconditionally on
  startup (the concrete `LottieBakeService`'s constructor, or a shared cache-sweep utility, deletes
  `LottieVideos\.baking-*.mov` / any leftover `.lottie` extraction temp dirs (§12) on init) — not a
  correctness requirement (a stale temp file is inert, never read by anything), a hygiene one.
- **User-initiated cancellation:** `BakeAsync`'s `CancellationToken` (§9) is wired to `PE_BakeLottieVideo`'s
  `cancelFlag` (§8) the same way every other cancellable native call in this codebase already bridges a
  C# `CancellationToken` to a native poll flag (mirrors `IExportService.ExportAsync`'s `ct.Register(...)`
  pattern, plan's Export section). A cancelled bake reports `LottieBakeStatus.Failed` via
  `StatusChanged` (not a fifth `Cancelled` status — cancellation and failure are observationally
  identical to a caller: no output, try again later if desired) with `ErrorMessage = "cancelled"` or
  similar, at the implementer's discretion.
- **Re-bake after a source-file edit:** re-exporting a Lottie from a design tool onto the *same*
  filesystem path naturally produces a different content hash (§5) — the next `TryGetCachedPath` for the
  same `(MediaRef, size)` misses, `BakeAsync` runs again, and the stale cache entry (a different
  filename, keyed off the OLD hash) is simply never looked up again. **v1 does not delete stale cache
  entries** — same posture as `DiskCache`'s existing entries generally (nothing in this codebase
  garbage-collects any disk cache today); a follow-up, not a v1 requirement.

## 14. Testing / golden hooks

- **`PE_EncodeAlphaVideo*` in isolation:** a native/C# test pushes a handful of synthetic frames (e.g. a
  solid color with varying alpha, or a simple gradient) through `Open`/`PushFrame`×N/`Close` and
  validates the resulting `.mov` structurally via `ffprobe` (matches the plan's own "Export integration
  test produces a real file validated structurally via `ffprobe`" pattern, and mirrors the existing
  `ExportServiceRoundTripTests` shape on the Mac) — asserting codec `prores_ks`⁄`pix_fmt` carries alpha
  (`yuva444p10le`), frame count, and duration match what was pushed (including a hold-tail case: two
  `PushFrame` calls with a large `presentationSeconds` gap between them, verifying the container reports
  the expected total duration despite only two encoded samples).
- **`PE_BakeLottieVideo` end-to-end:** a small, checked-in fixture `.json` (a trivial one- or two-shape
  Lottie, a handful of frames) baked at a fixed size, asserting: output file exists and is a valid
  `ffprobe`-parseable ProRes 4444 `.mov`; frame count/duration match the fixture's own known frame
  count/fps plus the hold-tail sample; a decoded frame's alpha channel is non-trivial (not fully opaque
  everywhere) if the fixture has a transparent region — a basic content sanity check, not full visual
  golden-frame comparison (that's a `docs/timeline-snapshot-v1.md`-style SSIM golden, out of scope for a
  first pass here since there's no Mac-rendered Lottie golden to compare against — ThorVG and Lottie-iOS
  are different renderers with no guaranteed pixel parity; visual comparison, if wanted later, would be
  ThorVG-output-vs-itself across a version bump, not ThorVG-vs-Mac).
- **`ILottieBakeService`'s cache/dedup logic (pure C#, no native needed):** unit tests against a fake
  `PE_BakeLottieVideo`-equivalent seam (mirrors `MediaVisualCache`'s own test seam,
  `MediaVisualCache.cs:69-79`'s `Func<string, MediaSource> openMedia` constructor overload) —
  `BakeAsync` called twice for the identical key while the first is "in flight" triggers only one
  underlying bake call; `TryGetCachedPath` returns non-null only after `StatusChanged` reports
  `Completed`; two different sizes for the same `SourcePath` are independent (§5).
- **`PE_ProbeLottieMetadata`:** asserts against the same fixture's known duration/size/frame rate — the
  cheapest test in this section, and useful as a fast native smoke test that doesn't invoke the encoder
  at all.

## 15. UI note (deferred, not part of this document)

No XAML/view code ships with this document — §1's scope is contract-only. If a future milestone adds a
visible "Baking…" indicator for a pending Lottie clip (consuming §10's `PendingLottieBakes` and/or §9's
`StatusChanged`), it must use `AppTheme` tokens per `platforms/windows/AGENTS.md`'s Design System rule —
never a hardcoded color. The existing "Media Offline" badge (`AssetTileControl.xaml:31-38`) already
establishes the pattern to follow (a `Border` overlay, `AppStatusErrorBrush` foreground, `AppFontSizeXs`/
`AppSpacingXxs` tokens) — a "Baking…" variant would reuse `AppThemeTokens.Status.Warning` (already
defined, `AppThemeTokens.cs:207`) rather than `Status.Error`, since a pending bake is transient/expected,
not a fault; if a dedicated "in progress" visual language is wanted instead of reusing Warning, a new
token is added to `AppThemeTokens.cs` + `Theme.xaml` + `ThemeParityTests` together, per that same rule —
never hardcoded, and never added speculatively before a real consumer needs it.

## 16. Agent split — who implements what

Mirrors `docs/audio-playback-v1.md` §9's convention: this document intentionally separates concerns so
the following can proceed in parallel once this document and the two ABI/interface declarations land.

| Slice | Owns | Key files |
|---|---|---|
| **vendor** | Fetch ThorVG v1.0.7, populate `native/third_party/thorvg/` per §3's exact file list, write `ThorVG.vcxproj` (static lib), link it into `PalmierEngine.vcxproj`, update `THIRD_PARTY_NOTICES.md`'s ThorVG entry from "decision landed" to "vendored" | `native/third_party/thorvg/`, new `ThorVG.vcxproj`, `PalmierEngine.vcxproj`, `THIRD_PARTY_NOTICES.md` |
| **encode** | `PE_EncodeAlphaVideo{Open,PushFrame,Close,Abort}` native implementation (avformat/avcodec `prores_ks` setup, BGRA→YUVA444P10LE handoff to the encoder, §7) — independently testable per §14 without ThorVG | new `native/AlphaVideoEncoder.h/.cpp` |
| **bake** | `PE_BakeLottieVideo` + `PE_ProbeLottieMetadata` native implementation (ThorVG `SwCanvas`/`LottieAnimation` open/rasterize loop, §6's frame-rate/count reads, hold-tail sample, temp-file+rename per §5/§13, wired to `encode`'s primitives internally) | new `native/LottieBaker.h/.cpp`, depends on **encode** and **vendor** |
| **service** | Concrete `LottieBakeService : ILottieBakeService` (C#) — `BakeVersion` constant, `DiskCache.ContentHashKey` addition (§5), in-flight dedup, `StatusChanged` wiring, `.lottie` zip extraction (§12), startup temp-file sweep (§13) | new `LottieBakeService.cs`, `DiskCache.cs` (additive method), depends on **bake** for the native call it wraps |
| **snapshot** | `TimelineSnapshotBuilder`'s real Lottie branch (§10), `TimelineSnapshotBuildResult.PendingLottieBakes` field, the rebuild-on-`Completed` subscriber wiring | `TimelineSnapshotBuilder.cs`, wherever `ProjectDocument`/timeline VMs already own `IVideoEngine` calls, depends on **service** |
| **probe** | `EngineMediaProbe.ProbeLottieAsync`'s real body (§11) | `EngineMediaProbe.cs`, depends on **bake** (shares `PE_ProbeLottieMetadata`, no dependency on **service**) |
| **ui** (optional, later) | A "Baking…" media-panel/timeline indicator (§15) | TBD view files, depends on **snapshot** |

**Dependency ordering:** **vendor** has no dependency on the others and should land first (or in
parallel with **encode**, which doesn't need ThorVG at all — §14's isolated encode tests can pass before
ThorVG is even vendored). **bake** depends on both. **service** and **probe** both depend only on
**bake**'s two native entry points and are otherwise independent of each other (can proceed in
parallel). **snapshot** depends on **service**. **ui** depends on **snapshot**.
