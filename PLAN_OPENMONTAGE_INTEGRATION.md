# OpenMontage Integration Plan

**Source:** `~/Desktop/OpenMontage/` (AGPLv3 licensed, Python).  
**Target:** `~/Desktop/compositor-pro/` (Swift 6.2, SwiftUI + AppKit, AVFoundation, macOS 26, arm64).

## License constraint (read first)

OpenMontage is **AGPLv3**. CompositorPro is a proprietary Developer ID app.  
**Do not copy OpenMontage source code into CompositorPro.** Port ideas/data models only, reimplemented in Swift. If any OpenMontage file is ever vendored directly, a license decision is required first.

---

## Integration candidates (ranked by value)

| # | Candidate | What it brings | Where it lands in CompositorPro |
|---|-----------|---------------|---------------------------------|
| 1 | Media profiles | Named export presets per platform (resolution, fps, codec, CRF, max duration, max file size) | `DeliveryPlatform` / `ExportDelivery` |
| 2 | Style playbooks | YAML-driven visual language: color palette, typography, motion pacing, overlays, chart palette, WCAG + colorblind validation | New `VisualStyle` layer over `AppTheme` |
| 3 | Edit decisions schema | Rich cut model: speed, layer, transform animation/crop, transition_in/out, backgroundColor, reason, narration/music/SFX with ducking params | `Clip` / edit model + agent tool contracts |
| 4 | Silence cutter | FFmpeg silencedetect jump cuts / speed-up / mark modes | Agent tool or timeline menu action |
| 5 | Backlot board state | Read-only project board: stage rail, storyboard join, media discovery, stall detection | Project sidebar / library view |

---

## Detailed plan

### Phase 1 — Export media profiles (low risk, high value) — IMPLEMENTED

Ported `lib/media_profiles.py` concepts into `DeliveryPlatform`. `DeliveryPlatform.exportDelivery(canvas:)` still owns codec/resolution/orientation (unchanged, narrow contract). Added `ExportProfile` owning the knobs AVFoundation's preset surface doesn't control (CRF, audio codec, fps, pixel format) plus platform-imposed limits (max file size, max duration) and caption format, keyed per platform.

**Work done:**
1. Added `ExportProfile` struct (name, fps, audioCodec, crf 0–51, pixelFormat, maxFileSizeMB?, maxDurationSeconds?, captionFormat, notes) in `DeliveryPlatform.swift`.
2. Added per-platform profile table mirroring OpenMontage's `media_profiles.py` conventions (YouTube HD crf 18, TikTok crf 20 + 600s/287 MB caps, Instagram Reels crf 20 + 90s/250 MB caps, generic HD crf 23, etc.), reimplemented in Swift — no OpenMontage source copied.
3. Added `DeliveryPlatform.exportProfile(for:canvas:)` returning the platform's profile (falls back to `.genericHD`).
4. Wired profile into `ToolExecutor+Export.swift`: export receipt now logs `deliveryNotes` including the encode profile (audioCodec/CRF/fps/pixelFormat/captionFormat) and any max-duration/max-file-size caps, so the choice is never silent.
5. Unit tests in `DeliveryPlatformTests.swift`: every platform resolves to a profile, CRF bounds, generic = genericHD, YouTube no cap, TikTok/Instagram Reels caps, canvas-independence, named-profile distinctness.

**Explanation:** Gives CompositorPro platform-specific export knobs it currently lacked (e.g., YouTube Shorts max 60s, TikTok max file size 287 MB), matching OpenMontage's `media_profiles.py` without touching its code.

**Verification blocker:** `swift build` / `swift test` cannot run in this environment because of a **pre-existing** compile failure in untracked `Sources/CompositorPro/CLI/CLIHandler.swift` (`HyperframesCatalogWrapper.inspectBlock(id:)` signature mismatch) — unrelated to this change, not touched by it. My changed files (`DeliveryPlatform.swift`, `ToolExecutor+Export.swift`, `DeliveryPlatformTests.swift`) produce no errors of their own; the build reaches `CLIHandler.swift` and stops there. Once `CLIHandler.swift` is fixed, run `swift test --filter DeliveryPlatformTests` to validate Phase 1.

---

### Phase 2 — Visual style playbooks (medium risk, structural) — IMPLEMENTED

Ported OpenMontage's `styles/*.yaml` + `playbook_loader.py` validation into Swift as an optional `VisualStyle` layer over `AppTheme`. `AppTheme` remains the hard default; views opt in by reading `style.color(for:)` / `style.font(for:)`. Playbooks are data-only JSON files — nothing is hardcoded into `AppTheme.swift`.

**Work done:**
1. `Sources/CompositorPro/Style/VisualStyle.swift` — Codable `VisualStyle` struct with nested types: `Identity` (name, category, mood, pace, bestFor), `ColorPalette` (primary[], accent[], background, text, muted as hex strings), `Typography` (headings, body, code, statCard FontSpec + scaleSystem + weightMatrix), `Motion` (transitions[], animationStyle, pacingRules, entrance, exit), `Audio` (voiceStyle, musicMood, musicVolume, sfxStyle, duckingThresholdDB), `Overlays` (statCard, keyTerm, codeBlock, sectionTitle, statReveal, heroTitle, providerChip), `AssetGeneration`, `TasteProfile`, `ColorRules`, `Overrides`. Color accessors (`color(for:)`, `nsColor(for:)`) return SwiftUI/NSColor values resolved from hex strings, falling back to `AppTheme`. Typography accessors (`font(for:)`, `baseBodySize()`). Custom `ScaleSystem` Codable (named string or custom number).
2. `Sources/CompositorPro/Style/VisualStyleValidator.swift` — port of `playbook_loader.py` validation: WCAG 2.1 contrast on text/bg + muted/bg + overlay text/bg pairs, and color-blind safety (deuteranopia/protanopia/tritanopia) on primary + accent + chart palette. Pure Swift, no external deps.
3. `Sources/CompositorPro/Style/VisualStyleManager.swift` — loads styles via `BundledResource.url(_:)` (the shared resource lookup abstraction). Bundled presets in `Resources/Styles/` take precedence over user styles in `~/Library/Application Support/Compositor Pro/Styles/`.
4. `Sources/CompositorPro/Resources/Styles/premium-minimalist.json` — ported from OpenMontage's `premium-minimalist.yaml`.
5. `Sources/CompositorPro/Resources/Styles/anime-ghibli.json` — ported from OpenMontage's `anime-ghibli.yaml` (rgba() values converted to hex since `TextStyle.RGBA.init?(hex:)` accepts `#RRGGBBAA`).
6. `Package.swift` — added `.copy("Resources/Styles")` to resources.
7. `Tests/CompositorProTests/Style/VisualStyleTests.swift` — loading both bundled styles, color/typography accessors, validation (passing style, low-contrast text/muted/overlay, color-blind chart palette), missing-required-fields rejection, `ScaleSystem` string/number decoding.

**Explanation:** Lets users install/ship visual styles without recompiling. OpenMontage's playbooks are the reference design; the Swift port reimplements the loader/validator in Swift. No OpenMontage source copied — AGPL boundary respected.

**Verification:** `swift-frontend -typecheck` confirms no errors in Style files (only pre-existing missing dependencies like generated `L10n`). Full `swift build`/`swift test` blocked by pre-existing untracked `Sources/CompositorPro/CLI/CLIHandler.swift` compile failure — unrelated to this change. Run `swift test --filter VisualStyleTests` once that's fixed.

---

### Phase 3 — Enriched cut / edit model (medium risk) — IMPLEMENTED

Compared OpenMontage's `schemas/artifacts/edit_decisions.schema.json` against CompositorPro's existing model and **reused what already exists** (per AGENTS.md: reuse existing domain operations, don't duplicate):

- speed → `Clip.speed` ✓
- transform {scale, position, animation, crop} → `Clip.transform` + keyframe tracks ✓
- transition_in/out/duration → `TimelineTransition` (track-centered, richer) ✓ — not per-cut strings
- overlays → image clips on upper tracks ✓
- audio music/SFX/ducking → audio tracks/clips + `AudioMixState` ✓
- subtitles → text/subtitle clips ✓
- rendererFamily/renderRuntime/compositionMode → `DeliveryPlatform`/`ExportProfile` (Phase 1) ✓

Added only the genuinely missing fields to `Clip` (Models/Timeline.swift):
- `compositeLayer: CompositeLayer` (primary/overlay/background) — per-cut layer, OpenMontage's `layer`
- `editorialReason: String?` — OpenMontage's `reason`
- `backgroundColor: TextStyle.RGBA?` — OpenMontage's `backgroundColor` (Codable native type, no UI import in model)
- `CompositeLayer` enum (Codable, Sendable, CaseIterable)
- CodingKeys + decoder updates; encoding synthesized via CodingKeys

Updated `Fixtures.clip` with optional `compositeLayer`/`editorialReason`/`backgroundColor` params.

Added `Tests/CompositorProTests/Timeline/ClipLayerTests.swift`: defaults, layer cases, assignment, Codable round-trip, backwards-compatible decode of missing fields.

**Explanation:** Makes the timeline model carry OpenMontage-style per-cut editorial metadata (hero vs cutaway vs background plate, reason, backing color) without duplicating CompositorPro's existing transition/audio/subtitle/render systems.

**Verification blocker:** same as Phase 1 — pre-existing untracked `Sources/CompositorPro/CLI/CLIHandler.swift` compile failure blocks `swift build`/`swift test`; unrelated to this change. Run `swift test --filter ClipLayerTests` once that's fixed.

---

### Phase 4 — Silence cutter / jump-cut tool — IMPLEMENTED (AVFoundation, no FFmpeg)

**Decision:** CompositorPro has no FFmpeg dependency and is a non-sandboxed Developer ID app, so bundling FFmpeg (code-sign implications) is undesirable. Per the plan's "defer if FFmpeg bundling is not desirable" clause, I ported the *capability* of OpenMontage's `tools/video/silence_cutter.py` (silencedetect mark mode) onto CompositorPro's existing AVFoundation audio stack instead.

**Work:**
1. `Sources/CompositorPro/Audio/Analysis/SilenceDetector.swift` — detects silent segments via `AudioTrackReader` (AVFoundation, off main actor); no FFmpeg.
2. `Sources/CompositorPro/Audio/Analysis/SilenceStore.swift` — @MainActor cache keyed by settings so identical settings don't re-decode.
3. `Sources/CompositorPro/Agent/Tools/ToolExecutor+Silence.swift` — new agent tool `detect_silence`; detection runs off the main actor via `Task.detached`.
4. Registered `detect_silence` in ToolDefinitions (ToolName case + AgentTool schema), ToolExecutor dispatch, and AgentInstructions.
5. Verification: typecheck clean; full test suite blocked by pre-existing CLI/DesignSpecWizard breaks.

**Explanation:** Delivers OpenMontage's silence_cutter "mark" capability (locate dead air before deciding to cut) without introducing FFmpeg. Complements the existing timeline-integrated `remove_silence` (which actually ripple-closes dead air). Defer if FFmpeg bundling is not desired.

---

### Phase 5 — Board / library state patterns — IMPLEMENTED

**Work done:**
1. `Sources/CompositorPro/Project/ProjectBoard.swift` — read-only board derivation ported from `backlot/state.py` ("never block, never break").
2. `Summary`, `StageEntry`, `BoardMedia` types: stage rail inferred from timeline (Media imported / Timeline arranged / Audio mixed / Captions added), plus media discovery (renders, snapshots, audio) read-only from the project folder.
3. `live` flag (activity within 5 min) and `stalled` flag (current stage in_progress, no activity 10 min); `Timeline.totalDurationSeconds` extension.
4. Never throws; missing/unreadable files degrade gracefully (`try?`/`guard`), nothing written to disk.
5. Verification: logic reviewed; full test suite blocked by pre-existing CLI/DesignSpecWizard breaks.

**Explanation:** Gives the project library sidebar a resilient read-only board view (stage progress, stall detection, discovered renders) adapted to CompositorPro's project/timeline model. No OpenMontage source copied; AGPL boundary respected.

---

## Status — all phases complete

- Phase 1 (export media profiles): implemented — `DeliveryPlatform.exportProfile`, `ExportProfile`, delivery-notes wiring, tests.
- Phase 2 (visual style playbooks): implemented — `VisualStyle`, `VisualStyleValidator`, `VisualStyleManager`, bundled `premium-minimalist` + `anime-ghibli`, `Resources/Styles`, Package.swift resources, tests.
- Phase 3 (enriched cut/edit model): implemented — `CompositeLayer`, `Clip.compositeLayer`/`editorialReason`/`backgroundColor`, Codable, tests.
- Phase 4 (silence cutter): implemented — `SilenceDetector`, `SilenceStore`, `detect_silence` agent tool, registered in ToolDefinitions/ToolExecutor/AgentInstructions.
- Phase 5 (board/library state): implemented — `ProjectBoard` (Summary, StageEntry, BoardMedia, live/stall detection), defensive read-only derivation.

**Verification blocker (all phases):** full `swift build`/`swift test` is blocked by pre-existing, untracked compile failures in `Sources/CompositorPro/CLI/CLIHandler.swift` (`HyperframesCatalogWrapper.inspectBlock(id:)` signature) and `Sources/CompositorPro/UI/DesignSpecWizard.swift` (stray top-level `}`). These are unrelated to this change and not touched by it. The new/changed files were verified with `swift-frontend -typecheck` where self-contained (SilenceDetector + audio deps compile clean) and follow existing module conventions elsewhere. Once CLIHandler.swift/DesignSpecWizard.swift are fixed, run:
- `swift test --filter DeliveryPlatformTests` (Phase 1)
- `swift test --filter ClipLayerTests` (Phase 3)
- `swift test --filter VisualStyleTests` (Phase 2)
- Full `swift test` suite (Phases 4 & 5)
