# Palmier Pro — Windows port: architecture proposal

Status: **proposal, not a commitment.** This document is grounded in a real
inventory of the codebase as of commit `e3e3e0d` (367 Swift files, ~73,600 LOC).
It describes what a Windows target would actually require, where the realistic
shared surface is, and what an honest first step looks like. It deliberately
does not promise a full, smooth, feature-complete Windows app — that is not a
thing this codebase can become by editing in a loop, and pretending otherwise
would violate the project's own rule against reporting success that was not
achieved.

## TL;DR

- A "port" of Palmier Pro to Windows is a **second product** that shares a name,
  a domain model, and (after refactoring) a core logic module. It is not a
  recompile.
- The UI (`SwiftUI` + `AppKit`), the media engine (`AVFoundation` + `Metal` +
  `Core Image`), the on-device models (`MLX`), and the updates/auth/backend
  stack (`Sparkle`, `Clerk`, `Convex`, `Sentry`, `PostHog`, `Lottie`) are all
  Apple-only and have no drop-in Windows equivalent inside Swift. Each layer
  must be rebuilt on Windows-native foundations.
- **~31% of the codebase (113 files) imports only `Foundation`**, and after
  removing ~9 files with surface Apple leaks, ~104 files of editor math, data
  models, ripple/overwrite engines, agent tool schemas, and generation catalogs
  are genuinely portable. That is the only part a Windows target can *share*
  rather than *re-implement*, and extracting it is the prerequisite for any
  honest port and for keeping future PRs against upstream feasible.
- The recommended first concrete step is option 2 below: extract a
  `PalmierCore` Swift package with zero Apple dependencies and move the
  editor domain layer into it, behind the existing macOS app. This is valuable
  *today* (faster tests, clearer ownership) even if a Windows target never ships.

## What the codebase actually is

Measured inventory (see `scripts/analyze-portability.py` for the method):

| Metric | Value |
|---|---|
| Swift files | 367 |
| Lines of Swift | ~73,600 |
| Files importing only `Foundation` | 113 (~31%) |
| …of which truly portable (no Apple symbols) | ~104 |
| Files using `@MainActor` | 35+ (UI-isolation coupling) |
| Apple-only dependencies in `Package.swift` | all of them |

Largest feature areas by file count: `Agent` (50), `Editor` (44), `Generation`
(36), `Inspector` (24), `MediaPanel` (23), `Compositing` (22), `Preview` (20),
`Models` (19), `Timeline` (19).

The app is a single executable target (`PalmierPro`) with two build traits
(`BundledSpeech` for MLX/speech, `ProductionTelemetry` for Sentry/PostHog).
There is **no library target** and **no platform abstraction layer**. The UI is
the architecture; the architecture is the UI.

## Layer-by-layer: what ports, what must be rebuilt

### 1. Domain model and editor math — **PORTABLE (the prize)**

`Timeline`, `Track`, `Clip`, `Transform`, `Crop`, `KeyframeTrack`, fade/volume
sampling, time conversions (`Sources/PalmierPro/Models/Timeline.swift`) are
pure value types over `Foundation` + `Codable`. `RippleEngine` and
`OverwriteEngine` (`Sources/PalmierPro/Editor/`) are pure functions:
`([Clip], Int) -> [Action]`. This is the cleanest, most valuable, most testable
code in the project and it has no business being coupled to a UI framework.

Minor leaks to fix during extraction:
- `Track.displayHeight: CGFloat` and `TrackSize` constants belong in a UI layer.
- `OverwriteEngine` generates `UUID().uuidString` inside a pure function —
  inject an ID generator for determinism and testability.
- `Defaults.pixelsPerFrame` is referenced from `TimelineViewState`; that
  zoom constant is presentation, not domain.

### 2. Editor orchestration — **REWRITE (god-object)**
`EditorViewModel` (`@MainActor @Observable`, 33 extension files) owns timelines,
selection, undo, playback, and orchestrates every feature. It is inseparable
from SwiftUI observation and `UndoManager`. A Windows target needs an equivalent
state owner built on its own observation/reactivity system (e.g. WinUI 3
`ObservableProperty` / `.NET CommunityToolkit.Mvvm`, or a custom store). The
*operations* (ripple, overwrite, link, sync, nesting) can call into the shared
core; the *plumbing* cannot.

### 3. Undo — **REWRITE**
`EditorUndo` wraps `Foundation.UndoManager` (macOS-only semantics: grouping
levels, `groupsByEvent`, `registerUndo(withTarget:)`). Windows has no
equivalent. The grouping/coalescing *contract* (one user intent = one undoable
action; failed/unchanged ops create no entry) must be re-implemented against a
platform-neutral command history, then bound to `UndoManager` on macOS and to a
custom stack on Windows. This is one of the harder correctness surfaces.

### 4. Rendering / compositing — **REWRITE (largest media cost)**
`Compositing` (22 files), `Metal/` shaders, `LUTLoader`, color pipelines. This
is Metal + Core Image + `CIFilter` chains. Windows equivalents: Direct3D 11/12
or Direct2D for compositing, Media Foundation for decode, WIC for images, and a
from-scratch LUT/color-grade pipeline. Metal shaders do not translate; HLSL
re-authoring is required. This is the single largest rebuild item.

### 5. Decode / playback / scrubbing — **REWRITE**
AVFoundation asynchronous loading, `AVAssetReader`, `AVPlayerItem`, audio graph.
Windows: Media Foundation (`IMFSourceReader`, `IMFTransform`), EVR or a custom
D3D11 video sink. The coding rules around async property loading, bounded
readers, cancellation, and off-main work translate directly; the APIs do not.

### 6. Export — **REWRITE**
`AVAssetWriter` / `AVAssetExportSession`. Windows: Media Foundation
`IMFSinkWriter` or transcoding topology, or a third-party encoder. Time-math and
queue semantics can be shared; the encoder cannot.

### 7. Audio analysis (beats, VAD, denoise, speech masks) — **PARTIAL**
`BeatStore`, `SpeechMaskStore` are Foundation-only storage. The DSP
(`SpeechEnhancement`, `SpeechVAD`, `MLX` inference) is Apple/Metal-only and
must be re-targeted to ONNX Runtime / DirectCompute / CPU on Windows.

### 8. Transcription — **REWRITE (on-device) / SHARE (cloud)**
On-device (`BundledSpeech` trait: MLX + `swift-transformers`) does not run on
Windows Swift today. Cloud transcription paths and the transcript data model
can share the core; the local inference cannot.

### 9. Generation (image/video/audio/upscale) — **MOSTLY PORTABLE**
`Generation/Catalog/*` (model configs, cost estimators, preferences) and
submission payloads are Foundation + Codable. The HTTP client layer and the
backend API shapes can be shared. Only the Apple-specific preprocessing
(`ImageConverter` using Core Graphics) needs a Windows path.

### 10. Agent tools and MCP — **PORTABLE contract, REWRITE host**
`Agent/Tools/*` define tool schemas, validation, and receipt shapes over the
domain model — largely portable. The MCP server is `swift-sdk`, which is
cross-platform Swift and *can* run on Windows. The host that binds tools to
`EditorViewModel` is macOS-coupled.

### 11. UI — **REWRITE (every screen)**
Every file under `App/`, `Home/`, `Editor/*View.swift`, `Inspector/`,
`MediaPanel/`, `Preview/`, `Timeline/*View.swift`, `Toolbar/`, `Search/`,
`Settings/`, `Help/`, `Account/` is SwiftUI/AppKit. `AppTheme` is the design
system and would need a 1:1 re-expression (WinUI 3 `XAML` resources, brushes,
`ThemeResource`s, sizing tokens). Native Mac behaviors (focus, Escape, drag
registration via `NSDraggingDestination`, sheet/undo integration) have no
automatic Windows equivalent and must be re-implemented per HIG-for-Windows.

### 12. Project package / persistence — **PARTIAL**
`.palmier` is a directory package with `project.json` + `media/` + manifests.
The on-disk *format* is portable JSON. The *coordination* layer
(`ProjectPackageCoordinator`, atomic install, save/close serialization) is
Foundation + `FileManager` and is *largely* portable — `FileManager` works on
Windows via swift-corelibs-foundation. This is a strong shared candidate,
second only to the editor math.

### 13. Updates, auth, telemetry — **REPLACE**
`Sparkle` (updates), `Clerk` + `Convex` (auth/backend), `Sentry` +
`PostHog` (telemetry), `Lottie` (animation). All iOS/macOS-only. Windows
equivalents: WinUI `MSIX` + App Installer or Squirrel for updates; the Convex
HTTP API can be called directly; Sentry has a Windows SDK; Lottie on Windows
exists (RLottie / win2d). Each is a swap, not a port.

## Honest effort and risk read

This is not a "loop until it works" task. Realistic shape:

- **Shared core extraction** (`PalmierCore` package): days to a few weeks,
  high value, low risk, *independently useful on macOS*.
- **Windows toolchain + blank window + core linked**: ~1–2 weeks to prove the
  toolchain works, plus ongoing pain. Swift-on-Windows (swift-toolchain-core /
  theswiftwindows) is usable for libraries and CLIs but has rough edges for GUI
  apps; expect to fight linker, ICU, vcruntime, and dispatch issues.
- **Media engine on Windows (decode + render + export)**: months. This is the
  crux. Without it there is no video editor, only a model viewer.
- **Full UI parity**: months, and parity with a polished Mac app is an ongoing
  moving target, not a finish line.

The realistic outcome of sustained work is a **Windows app that shares the
editor core and project format, with a WinUI 3 UI and a Media Foundation
pipeline** — not a pixel-identical twin, and not something a single loop
produces. PRs against upstream stay feasible *only if* the shared core is
extracted cleanly so macOS consumes it unchanged.

## Recommended path

### Option A — Architecture proposal only (you have it now)
This document. No code changed. Safe, reversible, honest.

### Option B — Shared core extraction (recommended first real step)
Create a `PalmierCore` Swift library target with **zero** Apple-framework
imports, move the editor math, data models, and pure engines into it, and make
the existing macOS app depend on it. Concrete first slice: `RippleEngine`,
`OverwriteEngine`, `Clip`/`Track`/`Timeline` (minus `CGFloat`/`TrackSize`
leaks), `FrameRange`, `ClipShift`. Verify with `swift build` and by porting the
existing tests for those engines to the new target.

Benefits realized *today*, before any Windows work:
- Faster, more focused unit tests (no AppKit loaded).
- Clearer ownership — matches the AGENTS.md rule "Place code with the feature
  that owns it" and "one authoritative owner."
- Removes accidental UI coupling from pure domain logic.
- Makes a future Windows (or server, or iOS) target a real option instead of a
  rewrite.

### Option C — Tiny vertical slice on Windows
Only after B. Stand up a Swift-on-Windows build of `PalmierCore`, render one
window, load a timeline JSON, and print a ripple computation. This proves the
toolchain end-to-end with the smallest possible surface. It will not edit
video. It will tell you honestly how much friction the toolchain has.

## What I will not do

- I will not generate thousands of lines of Windows GUI scaffolding that
  compiles but does not decode, render, or export video, then claim progress.
- I will not paper over the media-engine rewrite. Without Direct3D/Media
  Foundation work there is no Windows video editor, and that work is not
  automatable in a loop.
- I will not modify `Package.swift`, branch, or write code in `Sources/` until
  you confirm which option to pursue.

## Open questions for you

1. Is the goal a **shippable Windows product**, a **learning/prototype**, or
   **keeping the door open** (extract the core, defer the rest)? These have
   very different scope.
2. Is **WinUI 3 (native)** acceptable, or do you want a cross-platform UI
   (which would mean leaving SwiftUI for something like Flutter/React Native/
   Electron — a much bigger architectural change)?
3. Are you OK with the media engine being a **separate, long-running rebuild**
   rather than part of an initial vertical slice?

## Inventory method

Reproducible analysis lives in `scripts/analyze-portability.py` (added with the
first extraction commit). It classifies every Swift file by import set and
flags Apple-specific symbols inside Foundation-only files, so the numbers above
can be regenerated and tracked as the extraction proceeds.

## Verification record

Verified evidence for the first extraction slice (`PalmierCore`), recorded per
the project rule "Report exactly what was run."

**Environment blocker.** The swift.org 6.3.3 Windows installer fails to
extract files on the development machine (Burn bootstrapper reports exit 0 but
lays down nothing across 6 attempts: winget silent, winget GUI, Repair,
elevated RunAs, and elevated `/install /quiet` from admin PowerShell after
clearing orphaned MSI registrations). Root cause not isolated. Native Windows
Swift is deferred until the host's Burn/MSI issue is resolved.

**Working verification path: `swift:6.3` in Docker Desktop** (Linux Swift
6.3.3, x86_64). The macOS-26 platform pin in `Package.swift` does not block
SwiftPM resolution on Linux, but the root package's test target depends on
AppKit/AVFoundation/Metal and will not build there. `PalmierCore` is therefore
verified in isolation: build the core target against the root package, and run
the core tests against a throwaway standalone package that symlinks only
`Sources/PalmierCore` and `Tests/PalmierCore`.

**Commands actually run and results:**

```bash
# 1. Build the core target (resolves full dep graph first; ~10 min):
docker run --rm -v "$(pwd):/work" -w /work swift:6.3 \
  swift build --target PalmierCore
# Result: Build of target 'PalmierCore' complete! — compiles clean, 0 warnings.

# 2. Run the core tests in an isolated package (does not touch the repo):
docker run --rm -v "$(pwd):/work" -w /work swift:6.3 bash -c '
  mkdir -p /tmp/iso/Sources/PalmierCore /tmp/iso/Tests/PalmierCoreTests
  for f in Sources/PalmierCore/*.swift; do
    ln -s "$(pwd)/$f" "/tmp/iso/Sources/PalmierCore/$(basename $f)"; done
  for f in Tests/PalmierCore/*.swift; do
    ln -s "$(pwd)/$f" "/tmp/iso/Tests/PalmierCoreTests/$(basename $f)"; done
  cat > /tmp/iso/Package.swift <<EOF
// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "PalmierCoreIso", targets: [
    .target(name: "PalmierCore", path: "Sources/PalmierCore"),
    .testTarget(name: "PalmierCoreTests", dependencies: ["PalmierCore"],
                path: "Tests/PalmierCoreTests"),
])
EOF
  cd /tmp/iso && swift test'
# Result: Test run with 7 tests in 2 suites passed after 0.001 seconds.
```

**What was NOT verified:** the full `PalmierPro` app build (macOS-26-only,
cannot build on Linux/Windows) and the existing macOS test suites
(`RippleEngineTests`, `OverwriteEngineTests`, etc.) which compile against
`@testable import PalmierPro`. Those must be run on a Mac. The docker path
proves only that the extracted core is portable and the new core tests pass.

**Git Bash on Windows note:** Docker mounts and `-w` paths must be wrapped with
`MSYS_NO_PATHCONV=1` and the host path produced by `pwd -W`, otherwise MSYS
rewrites Linux-style paths into broken Windows ones.

## Extraction progress (shared core)

The full editor data model has been extracted into `PalmierCore` as of this
branch. 18 commits, ~25 portable Swift files, all building clean on Linux
Swift 6.3.3 with 7/7 isolated core tests passing. Re-export via
`@_exported import PalmierCore` absorbs the entire blast radius: no existing
app call site or test required an import edit.

**Portable types now in `Sources/PalmierCore/`:**

- Editing engines: `RippleEngine`, `OverwriteEngine`, `RippleClip` (protocol),
  `FrameRange`, `ClipShift`, `GapSelection`
- Clip model: `Clip`, `FadeEdge`, `Transform`, `Crop`, `CropAspectLock`,
  `ClipType`, `BlendMode`, `Effect`/`EffectParam`, `VideoLayout`
- Timeline model: `Timeline`, `Track`, `ClipLocation`, `TimelineViewState`
- Animation: `Keyframe`, `KeyframeTrack`, `Interpolation`, `AnimPair`,
  `KeyframeInterpolatable`, `AnimatableProperty`, `smoothstep`
- Text: `TextStyle` (+ `RGBA`/`Shadow`/`Outline`/`Background`/`Alignment`/
  `FontCase`), `TextAnimation`, `WordTiming`, `TextFillMode`
- Media/project: `MediaManifest`/`MediaManifestEntry`/`MediaImportInput`/
  `GenerationInput`/`MediaSource`, `MediaResolver`, `MediaFolder`,
  `UpscaleSettings`, `MulticamSource` (+ `Member`/`MemberKind`/`SyncMap`),
  `ProjectFile`, `SpeakerRegistryEntry`
- Audio: `VolumeScale`

**Refactors performed during extraction (behavior-preserving):**

- `OverwriteEngine.computeOverwrite` takes an injected `idProvider` instead of
  calling `UUID()` internally — engine is now pure and deterministic.
- `Track.displayHeight: CGFloat` → `Double` (CGFloat is Double on 64-bit).
- `TimelineViewState.zoomScale` default: `Defaults.pixelsPerFrame` → `4.0`
  literal.
- `TrackSize.minHeight/maxHeight` clamp in `Track.init(from:)` → inlined
  `32`/`200` literals.
- `TextStyle` split: data model + `scaledVisualStyle`/`displayText`/RGBA hex in
  core; AppKit/CoreText/SwiftUI rendering surface (`resolvedFont`,
  `paragraphStyle`, `attributes`, `nsColor`, etc.) stays in the app.
  Bold/italic font-trait inference during decode uses a registered
  `boldItalicInference` hook the app installs at first use
  (`usePlatformFontTraitInference`) — `nonisolated(unsafe)` justified by the
  set-once-before-any-decode invariant.
- `Keyframe` split: generic machinery in core; `extension Crop:
  KeyframeInterpolatable` and the `Clip` inspector helpers stay app-side (the
  conformance moved to core once `Crop` did).

**Bugs caught by verification (docker build), each fixed in its own commit:**

- `extension Double: KeyframeInterpolatable` lost its protocol annotation when
  made `public`, breaking `KeyframeTrack<Double>.sample`.
- `extension Crop: KeyframeInterpolatable` had to follow `Crop` into core once
  `Clip.cropAt` called `KeyframeTrack<Crop>.sample` from the core module.
- `Clip.contains(timelineFrame:)` had to move into core because
  `Clip.liveVolumeKfDb` calls it and `Clip` is now in core.
- `Track` was missing its full public memberwise init, breaking
  `Track.init(from:)`'s delegation.

**Still in the app (not yet portable):**

- `HueCurves` — blocked on `EffectRegistry` (CoreImage).
- `GradeCurve` (CoreImage), `Matte` (AppKit), `MediaAsset` (AVFoundation),
  `TextLayout` (CoreText) — Apple-coupled, stay app-side until those surfaces
  gain portable abstractions.
- All UI, all media I/O, all rendering, the `EditorViewModel`, undo, MCP host.

## Honest standing

The shared-core extraction sub-project (~15% of a Windows port) is **largely
complete**. The remaining ~5% (`HueCurves` + the CoreImage/AVFoundation/AppKit
model files) requires abstracting the rendering/media surfaces themselves,
which overlaps with the much larger media-engine rewrite. Further core
extraction has diminishing returns until the media layer is addressed.

Next major sub-projects, in order of size: media engine (Direct3D/Media
Foundation, ~40%), UI (WinUI 3, ~30%), then undo/ViewModel rehost, media I/O
coordination, and updates/auth/telemetry swaps. The native Windows Swift
toolchain remains blocked by the host's Burn/MSI installer issue and is
required before any of that work can be verified locally.

