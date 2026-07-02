# Phase 1 Implementation Plan — External Media Providers (MCP-first)

Design: [`../design/external-media-providers.md`](../design/external-media-providers.md)

## Goal

Prove the full path — **browse an external catalog → import an asset into the project
library** — end to end, with **no UI**, against the two galleries already running locally
(`downloads` :4617, `projects` :4618, ~260 videos). Success = an agent (or a test) can call
`list_sources`, `list_source_assets`, `import_source_asset`, and the asset lands in
`get_media` as an ordinary local asset.

### In scope
- `AssetProvider` protocol + `AssetProviderRegistry`.
- `GalleryProvider` adapter (covers both `downloads` and `projects`).
- Three MCP tools: `list_sources`, `list_source_assets`, `import_source_asset`.
- A shared **localhost import** path (refactored out of `importFromURL`).
- `MediaImportInput` provenance fields (`providerId`, `providerRef`).

### Out of scope (later phases)
- Sources tab UI (Phase 2). `PhotosProvider` / `BridgeProvider` (Phase 3). Timeline drag,
  "reveal in source" (Phase 4). Auto-starting servers.

## File map

New:
```
Sources/PalmierPro/MediaProviders/
  AssetProvider.swift        // protocol + AssetCard/ListQuery/ListResult/AssetType
  AssetProviderRegistry.swift// static provider list + lookup + config (ports)
  GalleryProvider.swift      // downloads/projects adapter
Sources/PalmierPro/Agent/Tools/
  ToolExecutor+Sources.swift // list_sources / list_source_assets / import_source_asset
```
Edited:
```
Sources/PalmierPro/Agent/Tools/ToolDefinitions.swift  // +3 AgentTool entries
Sources/PalmierPro/Agent/Tools/ToolExecutor.swift     // +3 ToolName cases, dispatch
Sources/PalmierPro/Agent/Tools/ToolExecutor+Import.swift // extract shared import core
Sources/PalmierPro/Models/MediaManifest.swift         // +providerId/providerRef on MediaImportInput
```

## Task breakdown (ordered, each independently verifiable)

### T1 — Contract types (`AssetProvider.swift`)
Port the design §3 contract verbatim. `AssetType`, `AssetCard`, `ListQuery`, `ListResult`,
`AssetProvider` protocol. All `Sendable`. `AssetCard` carries `type`, `ref`, `thumbnailRef`,
`isLocal`, `aspect` (display-only). No logic — pure model. **Verify:** `swift build`.

### T2 — Registry (`AssetProviderRegistry.swift`)
```swift
enum AssetProviderRegistry {
    static let providers: [AssetProvider] = [
        GalleryProvider(id: "downloads", label: "下载素材",
                        baseURL: url("DOWNLOADS_GALLERY_URL", "http://127.0.0.1:4617"),
                        listPath: "/api/videos", kind: .downloads),
        GalleryProvider(id: "projects", label: "自制成片",
                        baseURL: url("PROJECTS_GALLERY_URL", "http://127.0.0.1:4618"),
                        listPath: "/api/projects", kind: .projects),
    ]
    static func provider(_ id: String) -> AssetProvider? { providers.first { $0.id == id } }
}
```
Ports env-overridable (mirror vvcut env var names) with the §2 defaults. **Verify:** unit —
`provider("downloads")` non-nil, `provider("x")` nil.

### T3 — GalleryProvider (`GalleryProvider.swift`)
One adapter, `kind` switches the row mapping. Uses `URLSession.shared.data(from:)` for
`list`; `fetchURL` composes `baseURL + ref`. `health()` = short-timeout GET on `listPath`.

Response mapping (from the live gallery servers, confirmed via vvcut's `downloads.ts` /
`projects.ts`):

| Field | `downloads` (`/api/videos`) | `projects` (`/api/projects`) |
|---|---|---|
| rows | `env` array or `env.items` | `env` array or `env.projects`, **filter `p.video` present** |
| `id` | `row.id` | `row.id` |
| `name` | `title \|\| author \|\| "<source> · <id>"` | `title \|\| id` |
| `ref` (→ file) | `row.src` = `/media/<source>/<id>/video.mp4` | `row.video` = `/media/<id>/renders/video.mp4` |
| `thumbnailRef` | `row.poster` | `row.cover` |
| `description` | `source · author · resolution` | `status · <platforms>` |
| `durationMs` | `row.durationSec * 1000` | — |
| `isLocal` | `true` | `true` |
| `type` | `.video` | `.video` |

Search: galleries have no query API → fetch full list, AND-match `keys` (case-insensitive
substring over name/author/source/description/platforms per design §10.3), then paginate
`page`/`limit`. **Verify:** with galleries running, a tiny CLI/test calls
`list(.video, .init())` and prints counts — expect ~165 (downloads) / 101 (projects).

### T4 — Shared localhost import core (`ToolExecutor+Import.swift`)
`importFromURL` currently: requires `https`, infers `ClipType` from URL extension, builds a
placeholder, kicks `downloadImportedAsset`. Refactor the tail into a reusable core and add a
**loopback-http** entry that `import_source_asset` uses.

```swift
// New shared core — no scheme opinion; caller supplies validated URL + type + ext.
private func startRemoteImport(editor:, remoteURL: URL, type: ClipType, fileExt: String,
                               displayName: String, folderId: String?,
                               importInput: MediaImportInput) -> ToolResult
// existing importFromURL keeps its https guard, then calls startRemoteImport.
// new: importFromProvider validates host is loopback (127.0.0.1/localhost) AND port ∈
//      registry, derives type from the AssetCard.type (fallback: URL extension), calls core.
```
Security posture preserved: arbitrary `import_media` URLs stay **https-only**; only
registry-backed loopback URLs get the http exception, and the port must match a configured
provider. **Verify:** unit — loopback guard rejects a non-loopback host and a non-registry
port.

### T5 — Provenance fields (`MediaManifest.swift`)
Add to `MediaImportInput`: `var providerId: String?`, `var providerRef: String?` (both
optional → backward-compatible; manifest `version` unchanged). Populate from
`import_source_asset`. **Verify:** `swift build`; round-trip a manifest with the new fields.

### T6 — MCP tools (`ToolExecutor+Sources.swift` + wiring)
Add three `ToolName` cases, three `ToolDefinitions.all` entries, three dispatch arms.

- **`list_sources`** — no args. Returns `[{id,label,capabilities,online}]`. Calls
  `provider.health()` concurrently across the registry.
- **`list_source_assets`** — `{provider, type?, keys?, page?, limit?}`. `type` defaults per
  provider capability (galleries: `video`). Returns compact rows
  `[id, name, ref, durationMs?, description?]` + `hasMore` + a one-line `local:false` note if
  any. Cap `limit` (e.g. ≤100).
- **`import_source_asset`** — `{provider, ref, name?, folderId?}`. Resolves `fetchURL`,
  calls `importFromProvider`. Returns the placeholder id + `"Status: downloading. Poll
  get_media."` (identical UX to `import_media`).

Validate unknown keys (match the existing `validateUnknownKeys` pattern). These tools take
opaque provider refs, not clip ids — safe past `expandingIdPrefixes`/`shorteningIds`.
**Verify:** build + the E2E below.

## End-to-end verification

Preconditions: both galleries running (`node serve.mjs` in each `~/media/videos/*`), a
Palmier project open.

1. `list_sources` → both providers `online:true`, capability `video`.
2. `list_source_assets {provider:"downloads", keys:["douyin"]}` → non-empty, refs shaped
   `/media/douyin/.../video.mp4`.
3. `import_source_asset {provider:"downloads", ref:"<one>"}` → placeholder id, status
   downloading.
4. Poll `get_media` → asset present, playable, `importInput.providerId=="downloads"`.
5. Offline path: stop :4618, `list_sources` → `projects` `online:false`, no crash.

Drive via the MCP tools directly (this session can call them) once built — no unit harness
required for the E2E, though T2–T5 keep their small unit checks.

## Risks & mitigations
- **Gallery JSON drift** (field names differ from vvcut's assumptions). Mitigate: mapping is
  defensive (`??` fallbacks, array-or-envelope); T3 verify step prints a real row first.
- **Loopback exception widening attack surface.** Mitigate: exception is gated on *both*
  loopback host *and* a port present in the registry — not "any http".
- **No extension on future providers' file endpoints** (photos `/video/:uuid`). Not a Phase
  1 issue (galleries carry `.mp4`), but `importFromProvider` already derives type from
  `AssetCard.type` first, so Phase 3 is unblocked.
- **`aspect` leaking into clips.** Guard: `import_source_asset` never forwards `aspect`;
  it's list-display only.

## Sequencing
T1 → T2 → T3 (verify against live galleries here — first real signal) → T4 → T5 → T6 →
E2E. T4/T5 are independent of T3 and can overlap. Ship is one PR; the E2E is the gate.
