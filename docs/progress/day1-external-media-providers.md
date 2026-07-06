# Day 1 — External Media Providers

**Date:** 2026-07-02 → 07-03
**Commit:** `02835a9` feat(sources): external media providers + drag-to-timeline
**Goal:** Solve the media cold-start problem — let users browse and import from
catalogs they already own, exposed as local HTTP "bridge" servers.

## What shipped

A complete, live-verified path from *five local catalogs* → project library → timeline:

| Source | Bridge | Port | Adapter |
|---|---|---|---|
| Downloaded footage | downloads | 4617 | `GalleryProvider` |
| Past project cuts | projects | 4618 | `GalleryProvider` |
| macOS Photos | photos | 5374 | `PhotosProvider` |
| 剪映 cache | jianying | 5174 | `BridgeProvider` |
| CapCut cache | capcut | 5274 | `BridgeProvider` |

### Phase 1–2 — provider layer + Sources panel
- `AssetProvider` protocol + `AssetProviderRegistry` (Swift port of orca-vvcut's
  TS `Provider` contract). Loopback-only fetch guard; env-overridable URLs.
- `GalleryProvider` (downloads/projects), client-side search + pagination.
- Sources tab in the media panel: provider pills with health dots, search, an
  adaptive grid, and offline/loading/empty/error states.

### Phase 3 — Photos + editor-cache adapters
- `PhotosProvider` (video/image, iCloud gating via `isLocal`).
- `BridgeProvider` (剪映/CapCut music/sfx/image; audio split by `kind`).
- Multi-type sources get a type switcher (Image / Music / Sfx / Video).

### Phase 4 — provenance + polish
- `MediaProvenance {providerId, providerRef}` persisted on `MediaAsset` and
  manifest entries — powers "already imported" checkmark badges in the grid.

### MCP tools
- `list_sources`, `list_source_assets`, `import_source_asset` (registered under
  `mcpServer`, concurrent health checks via `withTaskGroup`).

### Drag-to-timeline (+ aspect fix)
- Drag a local card onto the timeline → **ingest on drop** (cancelled drags leave
  nothing behind): materialize a downloading placeholder clip at the drop point
  (auto-shows the generating overlay), copy in the background, then
  `finalizeGeneratingClip` fixes real duration/trim once the media lands.
- New `palmier-source://<base64-json>` pasteboard scheme (distinct from the
  library's `palmier-asset://`); reuses the existing drop-plan / snap / link path.
- **Aspect bug fixed:** the placeholder has no dimensions at drop, so first-clip
  auto-detect used to lock the 16:9 default. `adoptSettingsFromCompletedImport`
  now adopts the media's *real* resolution/aspect/fps once downloaded — only when
  that asset is the sole video, so it never clobbers a real multi-clip project.

## Key files
- `Sources/PalmierPro/MediaProviders/` — `AssetProvider`, `AssetProviderRegistry`,
  `GalleryProvider`, `BridgeProvider`, `PhotosProvider`, `SourceDragPayload`
- `Sources/PalmierPro/MediaPanel/SourcesTab/` — `SourcesTab`, `SourceCardView`,
  `SourceBrowserModel`
- `Sources/PalmierPro/Agent/Tools/` — `ToolExecutor+Sources`, `+Import` (refactored
  to return the placeholder asset), `ToolDefinitions`, `ToolExecutor`
- `Sources/PalmierPro/Editor/ViewModel/EditorViewModel+SourceDrag.swift`,
  `+ProjectSettings.swift` (aspect adoption)
- `Sources/PalmierPro/Timeline/TimelineView.swift` — drop-path branch
- `Models/MediaAsset.swift`, `Models/MediaManifest.swift` — provenance
- `scripts/run-signed.sh` — sign the debug binary with a stable identity so the
  keychain grant persists across launches (fixes per-build re-prompt)

## Verified
- Build clean; **17/17** provider + drag-payload tests pass.
- Live via MCP + real mouse (`cliclick`): imported douyin video, .mp3 audio, .jpg
  image; imported-badge appears via provenance.
- Drag-to-timeline: dropped a card → linked V+A clips placed, downloaded,
  rendering. Isolated aspect run adopted a real **1874×1080** source full-frame.

## Known gaps / next
- **Photos bridge** written + unit-tested only — not live-verified (needs a
  TCC-authorized `.app`).
- Slight non-identity clip transform (~0.976) after resolution adoption —
  cosmetic, fills frame.
- Multi-card / multi-select drag not exercised.

## Gotchas worth remembering
- `swift run` produces an ad-hoc binary with a per-build identifier → keychain
  re-prompts every launch. Use `scripts/run-signed.sh`.
- Bridge fetch URLs hide the extension in a query param (`/cache-file?p=...mp3`);
  infer type from the **ref** extension, with a `typeHint` fallback.
- Card `aspect` is cover art, not media dims — always read real dimensions from
  the imported asset (drove the aspect bug + fix).
