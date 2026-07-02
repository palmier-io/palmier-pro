# Design: External Media Providers

Status: Draft · Owner: TBD · Target: Palmier Pro (Swift 6.2, macOS 26)

## 1. Problem

The hardest part of starting a project in Palmier Pro is **getting media in**. A new
project opens on an empty timeline with an empty library; the only way to fill it is
`import_media` from a file path, a URL, or raw bytes. Everything the user already owns —
their macOS Photos library, footage they've downloaded, cuts they've already published,
music and images cached by other editors — is invisible to the app.

Meanwhile, that media is **already catalogued and served**. In `orca-studio`, five local
HTTP services expose these catalogs, and `orca-vvcut` browses all five through one
`Provider` TypeScript abstraction. Palmier has no equivalent consumer. The assets exist,
addressable over localhost; nothing in the Swift app knows how to list them.

**Goal:** give Palmier a first-class way to browse those five sources and pull an asset
into the project library with one drag — cold-start solved from media the user already has.

**Non-goals:** replacing `import_media`; managing/curating the source catalogs (they stay
read-only and owned by their own apps); auto-downloading iCloud originals; cloud/remote
providers (these are all localhost).

## 2. The five sources (verified contracts)

All five are local HTTP servers. Each offers a **list** endpoint returning cards and a
**file** endpoint that streams bytes with HTTP Range. They are the same servers `orca-vvcut`
proxies in `studio/src/lib/providers/*.ts`.

| Provider | Server | Port | Capabilities | List endpoint | File endpoint(s) |
|---|---|---|---|---|---|
| `photos` | photos-bridge | 5374 | video, image | `/api/ls`, `/api/ls-images` (`?keyword=&limit=`) | `/video/:uuid`, `/thumb/:uuid`, `/image/:uuid` (HEIC→JPEG), `/image-thumb/:uuid` |
| `jianying` | jianying-bridge | 5174 | music, sfx, image | `/api/cache/music`, `/api/cache/images` | `/cache-file?p=<rel>` |
| `capcut` | capcut-bridge | 5274 | music, sfx, image | `/api/cache/music`, `/api/cache/images` | `/cache-file?p=<rel>` |
| `downloads` | media/videos/downloads `serve.mjs` | 4617 | video | `/api/videos` | `/media/<rel>`, `/thumbs/<rel>` |
| `projects` | media/videos/projects `serve.mjs` | 4618 | video | `/api/projects` | `/media/<rel>` |

Real local inventory today: ~165 social videos (`downloads`), 101 rendered cuts
(`projects`), the full Photos library, plus 剪映/CapCut music/SFX/image caches.

Notes that the design must respect:
- **`local` flag.** Photos returns `local: false` for iCloud-only originals not yet
  downloaded. These must be shown but **not draggable** — Palmier never triggers an iCloud
  pull (that stays a manual action in photos-bridge's own UI).
- **Heterogeneous shapes.** photos uses `<kind>:<uuid>` refs and keyword params; the
  bridges use `rel`-path refs and return everything (client filters); the galleries return
  everything and client-paginate. The abstraction must absorb this.
- **Capabilities differ per provider.** A provider is only asked for types it declares.

## 3. The unified contract (Swift)

Mirror the `orca-vvcut` `Provider` interface (`studio/src/lib/providers/types.ts`) so the two
consumers stay at parity and porting logic is line-for-line.

```swift
enum AssetType: String, Sendable { case music, sfx, image, video }

struct AssetCard: Identifiable, Sendable {
    let id: String              // unique within provider
    let providerId: String
    let type: AssetType
    let name: String
    let ref: String             // provider-internal addressing string
    let thumbnailRef: String?
    let description: String?
    let durationMs: Int?
    let aspect: String?         // display-only; NEVER fed into the clip
    let isLocal: Bool           // false → present but not draggable (iCloud-only)
}

struct ListQuery: Sendable { var keys: [String] = []; var page = 1; var limit = 30 }
struct ListResult: Sendable { let items: [AssetCard]; let hasMore: Bool }

protocol AssetProvider: Sendable {
    var id: String { get }
    var label: String { get }
    var capabilities: Set<AssetType> { get }
    func list(_ type: AssetType, query: ListQuery) async throws -> ListResult
    func fetchURL(forRef ref: String) -> URL          // resolvable localhost URL for ingest
    func health() async -> Bool                        // server reachable?
}
```

Key difference from vvcut: vvcut's `fetchFile` returns proxied *bytes* because a browser
can't reach localhost cross-origin cleanly. Palmier is a native app with no CORS boundary,
so a provider just needs to hand back a **resolvable `URL`** (`http://127.0.0.1:<port>/...`).
Ingest reuses the existing URL import path — see §5.

### Registry

One `AssetProviderRegistry` with a static list, mirroring vvcut's `registry.ts`. Adding a
source is one entry. Ports are overridable via settings (defaults match the table above).

```swift
let providers: [AssetProvider] = [
    BridgeProvider(id: "jianying", label: "剪映素材", baseURL: ...),   // music/sfx/image
    BridgeProvider(id: "capcut",   label: "CapCut 素材", baseURL: ...),
    PhotosProvider(baseURL: ...),                                     // video/image
    GalleryProvider(id: "downloads", label: "下载素材", baseURL: ..., api: "/api/videos"),
    GalleryProvider(id: "projects",  label: "自制成片", baseURL: ..., api: "/api/projects"),
]
```

`BridgeProvider` is one shared implementation parameterised by `{id,label,baseURL}` — same
factoring as vvcut's `createBridgeProvider`, since jianying and capcut are isomorphic.
`GalleryProvider` similarly covers downloads/projects (both are `serve.mjs` galleries with
`/media` Range streaming; only the list endpoint + field mapping differ).

## 4. Where it lives in Palmier

New surface in the media panel — a **"Sources" browser** alongside the existing library.

- **`Sources/PalmierPro/MediaPanel/SourcesTab/`** (new) — provider switcher (top-level
  single-select, matching vvcut: no cross-source merge), a type filter driven by the
  selected provider's `capabilities`, a paginated card grid reusing `AssetThumbnailView`,
  and a search box wired to `ListQuery.keys`. Empty/greyed state for `isLocal == false`.
- **`Sources/PalmierPro/MediaProviders/`** (new) — the protocol, registry, and the three
  concrete adapters (`BridgeProvider`, `PhotosProvider`, `GalleryProvider`). Flat top-level
  feature dir, matching the existing convention (`MediaPanel/`, `Generation/`, `Search/`…).
- **Reuse for drop:** the panel already solves nested drop targets with AppKit
  (`MediaPanelDropArea`, per AGENTS.md). The Sources grid is a drag *source*, not a drop
  target, so it stays SwiftUI; drag payload carries the `AssetCard` (see §5).

## 5. Ingest flow (the cheap part)

Palmier already ingests from a URL: `import_media` accepts `source.url`, handled by
`ToolExecutor.importFromURL` → placeholder `MediaManifestEntry` (`generationStatus:
downloading`) → background copy → asset appears in `get_media`. Provider file endpoints are
plain localhost URLs, so **ingest is that existing path, unchanged.**

Drag/drop an `AssetCard` from the Sources grid:

1. Resolve `provider.fetchURL(forRef: card.ref)` → `http://127.0.0.1:<port>/...`.
2. Call the same import entry point as `source.url` import (extract a shared
   `EditorViewModel.importRemote(url:name:folderId:type:)` from `importFromURL` so UI and
   MCP share one path). Carry `card.name`, inferred `ClipType` from `card.type`.
3. Placeholder asset shows in the library with the download overlay
   (`ClipGeneratingOverlay`); on completion it's a normal local asset.
4. Record provenance in `MediaImportInput` — add `providerId`/`ref` next to the existing
   `sourceURL`, so a re-import or "reveal in source" is possible later.

Dragging a Sources card **directly onto the timeline** is Phase 2: ingest first (as above),
then drop the resulting asset — avoids referencing a not-yet-local file on a track.

Do **not** pass `card.aspect` into the clip — it's cover ratio only; the real ratio comes
from the decoded media (same rule as vvcut's `types.ts` comment).

## 6. Two integration strategies

**A. Native Swift adapters (recommended).** Palmier talks to the five servers directly,
reimplementing the ~30 lines of mapping per provider in Swift. No runtime dependency on
`orca-vvcut`. Parity with vvcut is by shared contract, not shared code. Most robust; the
servers are small and stable.

**B. Reuse the vvcut gateway.** Point Palmier at vvcut's Next app
(`/api/providers`, `/api/assets/file`) and let its TS providers do the mapping. One
integration point, zero re-implementation — but couples Palmier to a running Next server
and an extra proxy hop for every byte.

Recommendation: **A.** The mapping logic is trivial and already read; a native editor
shouldn't depend on a Next.js dev server being up to see its own footage. Keep the Swift
contract byte-identical to `types.ts` so B remains a fallback and future sources ported in
either repo transfer cheaply.

## 7. Server discovery & health

These servers are started manually (`node serve.mjs`, `cd web && node server.mjs`). Palmier
must degrade gracefully:

- `provider.health()` = a cheap `HEAD`/short-timeout GET on the list endpoint.
- Provider switcher shows each source's state: **online** / **offline (start hint)** /
  **empty**. Offline shows the exact command to start it, not an error.
- No auto-spawn in v1. (Possible later: a "Start source" affordance shelling out to the
  known command — out of scope here.)
- Ports configurable in Settings (new **Sources** pane), defaults per §2, env-overridable
  to match vvcut's env vars (`JIANYING_BRIDGE_URL`, `DOWNLOADS_GALLERY_URL`, …).

## 8. Data-model touchpoints

- `MediaImportInput` (`Models/MediaManifest.swift`): add `providerId: String?`,
  `providerRef: String?` alongside `sourceURL`. Backward-compatible (all optional).
- No change to `ClipType`, `MediaAsset`, or the timeline model — a provider asset becomes a
  perfectly ordinary imported asset once copied in.
- Thumbnails: fetch `card.thumbnailRef` lazily for the grid only; not persisted until
  ingest, at which point Palmier generates its own via `MediaVisualCache`.

## 9. Phasing

1. **Contract + one adapter, MCP-first.** `AssetProvider`, registry, `GalleryProvider` for
   `downloads`/`projects` (your two already-running galleries, ~260 videos). New MCP tools
   `list_sources` / `list_source_assets` / `import_source_asset` (thin wrappers over
   `importRemote`). Validates the whole path with no UI.
2. **Sources tab UI.** Provider switcher, grid, search, drag-to-library, health states.
3. **Photos + bridges.** `PhotosProvider` (video+image, `isLocal` gating) and
   `BridgeProvider` (jianying+capcut music/sfx/image). Full five-source parity.
4. **Timeline drag + provenance polish.** Direct-to-timeline (ingest-then-place),
   "reveal in source", re-import from `providerRef`.

## 10. Resolved decisions

### 10.1 MCP surface — three dedicated tools, mapping 1:1 to the protocol

Decision: **dedicated tools**, not a `provider:` scope bolted onto `search_media` /
`import_media`.

- `list_sources` — no args. Returns each provider's `id`, `label`, `capabilities`, and
  `health` (online/offline). The agent's discovery entry point.
- `list_source_assets` — `{ provider, type, keys?, page?, limit? }` → `AssetCard[]` +
  `hasMore`. Thin wrapper over `provider.list(type, query)`.
- `import_source_asset` — `{ provider, ref, name?, folderId? }` → resolves `fetchURL` and
  routes through the shared `importRemote` path (§5). Returns the placeholder asset id.

Rationale: (a) discoverability — an agent that can't see a provider list can't guess a
`provider:` scope; explicit tools + a capability matrix are self-describing. (b) Keeps
`import_media`'s source schema (`url`/`path`/`bytes`) clean instead of overloading it with a
fourth provider-ref mode. (c) The three tools map exactly onto the three protocol methods,
so the MCP layer stays a pass-through with no logic of its own. Cost is three tools vs. two
extended ones — cheap for the clarity. Phase 1 ships all three (they're the MCP-first
validation harness).

### 10.2 Audio — one browse surface (Sources), one library

Decision: **browse every type in the Sources tab** (video/image/music/sfx), gated by each
provider's `capabilities`. Do **not** split browse across Sources and the Music tab.

On ingest, an audio asset becomes an ordinary library asset and therefore *also* appears in
the existing **Music tab** — because that tab already filters the library by audio type.
So: Sources = "browse everything external in one place"; Music tab = "the audio already in
my project," unchanged. No new audio-browse surface, no duplication. jianying/capcut music
and sfx land as normal audio assets and are usable on audio tracks immediately.

### 10.3 Search — normalise the *semantics*, not the *location*

Decision: providers keep filtering wherever it's cheapest (photos: server-side `keyword`;
bridges/galleries: client-side over the fetched list), but the **contract** is uniform:

> `keys` are AND-matched, case-insensitive substring over the card's searchable text
> (`name` + `description`, plus provider-native fields like author/tags/platform).

Each adapter is responsible for honouring that semantic against its own backend. Galleries
and bridges return their full list, so the adapter caches it per session and filters in
Swift; photos passes `keyword` through and lets the server narrow first. This gives the user
(and agent) one predictable behaviour without forcing photos to give up server-side
efficiency or making the bridges invent a query API they don't have. Empty `keys` = list
all (subject to pagination).

### 10.4 Server lifecycle — manual in v1, opt-in menu action later, never bundled

Decision:

- **v1:** manual start (`node serve.mjs`, `cd web && node server.mjs`). `provider.health()`
  drives the UI; offline providers show the exact start command as a hint, never an error.
- **Later (opt-in):** a **"Start media sources"** menu action that shells out to the known
  commands for offline providers, surfacing output in a panel. Nice-to-have, not v1.
- **Rejected:** bundling a launchd helper. These servers live in independent dev repos
  (`orca-studio/*`, `~/media/videos/*`) with their own deps and ports; a bundled daemon
  would be fragile, invisible to the user, and couples Palmier's lifecycle to repos it
  doesn't own. Health + a start hint is the honest boundary.

## 11. Remaining open question

- **Live Photos / images:** photos-bridge treats Live Photos as stills (its own Phase 2
  does motion pairing). Fine to mirror for Palmier v1 — ingest the still, revisit motion
  once photos-bridge exposes the paired video.
