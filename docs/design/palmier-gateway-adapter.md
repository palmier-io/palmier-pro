# palmier-gateway adapter (`fork/orca-studio` vs `main`)

How the fork routes Palmier Pro's compute backend at a localhost gateway, and the exact
wire contract that gateway must satisfy.

Counterpart repo: `~/ghq/github.com/orca-studio/palmier-gateway` — an Express façade
(`server/index.mjs` + `server/translate.mjs`) over `orca-gateway-core`, spawning local
`orca-*` MLX skills. Ports 5474 (API) / 5480 (status panel). The contract below was checked
against that implementation; divergences are listed in *Client ↔ gateway mismatches*.

`main` and `fork/orca-studio` are fully merged (`git log main..fork/orca-studio` shows
only fork commits; nothing on `main` is missing). The fork adds two independent things:

1. **Local backend seam** — `PALMIER_BACKEND=local` swaps Convex + Clerk for HTTP calls
   against `palmier-gateway`. This document.
2. **External media providers** — a Sources tab plus three Agent tools reading local
   asset servers (Photos bridge, galleries, 剪映/CapCut caches). Separate concern,
   summarized at the end; designed in `docs/design/external-media-providers.md`.

## Design constraint

The adaptation must rebase cleanly onto upstream. So it is a *branch at each seam*, not a
protocol abstraction: `LocalBackend` mirrors the exact decoded types of the Convex seams,
and every call site adds one guarded early return. Upstream types are untouched — the
gateway is what conforms.

```
                    BackendMode.current
                           │
        .cloud ────────────┴──────────── .local
          │                                 │
  Convex (ConvexMobile)              LocalBackend (URLSession)
  Clerk auth / credits               no auth, no credits, no network
  reactive subscribe()               0.8 s polling publisher
```

## Selection

`Sources/PalmierPro/Backend/BackendMode.swift` — resolved once at launch, in order:

| Source | Value |
| --- | --- |
| `PALMIER_BACKEND` env | `local` |
| `UserDefaults` key `palmier.backendMode` | `"local"` |
| otherwise | `.cloud` |

Gateway base URL: `PALMIER_GATEWAY_URL`, default `http://localhost:5474`.

```bash
PALMIER_BACKEND=local PALMIER_GATEWAY_URL=http://localhost:5474 \
SIGNING_IDENTITY=C1169D0A26059CDD4209CC52F851C5BBD8076A89 \
scripts/run-signed.sh
```

## Touched seams

| File | Cloud path | Local path |
| --- | --- | --- |
| `Account/AccountService.swift` | Clerk sign-in, tier, credit budget | `configure()` returns early; `isSignedIn`/`isPaid` true, `remainingCredits == Int.max` |
| `Generation/Catalog/ModelCatalog.swift` | `convex.subscribe("models:list")` | one-shot `GET /api/models` with exponential backoff retry (cap 30 s) |
| `Generation/GenerationBackend.swift` | `generations:submit`, `generations:byId`, `uploads:commitUpload` | `POST /api/generate`, polled `GET /api/jobs/{id}`, staged-upload URL |
| `Transcription/TranscriptionBackend.swift` | `transcriptions:submit` / `:byId` / `:result` | `POST /api/transcribe`, polled `GET /api/transcriptions/{id}`, `GET …/result` |
| `Backend/BackendStorage.swift` | ticket + Convex staging PUT | `POST /api/uploads/stage` |

Everything downstream (job orchestration, download-and-install into the `.palmier`
package, undo, UI) is unchanged upstream code.

## Gateway HTTP contract

All bodies JSON, all paths relative to the base URL. Non-2xx is surfaced as
`BackendError.transport("gateway HTTP <code>: <body>")`, so put a human-readable reason in
the body. No auth header is sent.

### `GET /api/models`

```json
{ "models": [ CatalogEntry, … ] }
```

`CatalogEntry` is decoded by `ModelCatalog.swift` and is the widest part of the contract.
Required: `id`, `kind` (`video|image|audio|upscale`), `displayName`, `allowedEndpoints`
(`[String]`), `responseShape` (`video|images|audio|upscaledImage`), `uiCapabilities`.
Optional: `providerName`, `description`, `creditsPerSecond`, `audioDiscountRate`,
`creditsPerImage`, `qualities`, `audioPricing`, `creditsPerSecondUpscale`,
`upscalePricing`, `paidOnly` (defaults `false`).

`uiCapabilities` is decoded per `kind` as `VideoCaps` / `ImageCaps` / `AudioCaps` /
`UpscaleCaps` — see `ModelCatalog.swift`. These drive the generation UI's pickers and
validation, so a mismatch surfaces as missing durations/aspect ratios rather than an error.
A decode failure of *any* entry fails the whole list and the catalog retries with backoff.

### `POST /api/generate`

```json
{ "model": "<catalog id>", "params": { "kind": "video", … }, "projectId": "…"|null }
→ { "jobId": "…" }
```

`params` is a tagged union — `kind` is `video` | `image` | `audio` | `upscale`, with the
remaining fields of the corresponding `*GenerationParams` (see appendix). Optional fields
and empty reference arrays are omitted from the encoding, so treat absence as default.

### `GET /api/jobs/{jobId}`

Polled every 0.8 s until terminal; the client cancels the publisher itself.

```json
{ "_id": "…", "status": "queued|running|succeeded|failed",
  "resultUrls": ["https://…"]|null, "errorMessage": null, "costCredits": null,
  "completedAt": null }
```

**`_id`, with the underscore** — a Convex artifact the fork kept to avoid touching the
upstream type. (Transcription jobs use plain `id`; don't unify them.) `resultUrls` must be
plain GET-able URLs; the client downloads them and installs into the project package.
A non-decodable body is swallowed by the poller and retried, so a malformed job response
hangs the job rather than failing it.

### `POST /api/uploads/stage`

Raw file body (`URLSession.upload(fromFile:)`), `Content-Type` set to the asset's type.

```json
→ { "storageId": "…" }
```

The staged bytes must then be served at `GET /files/staging/{storageId}` — that URL is
what `uploadReference` hands back as the reference-image/video URL inside generation
params, so the model provider (or local worker) must be able to read it.

### `POST /api/transcribe`

```json
{ "storageId": "…", "durationSeconds": 12.5,
  "languageMode": "auto"|"specific", "language": "en"|null }
→ { "jobId": "…" }
```

### `GET /api/transcriptions/{jobId}`

Polled at 0.8 s: `{ "id": "…", "status": "queued|running|succeeded|failed", "errorMessage": null }`.

### `GET /api/transcriptions/{jobId}/result`

`{ "resultUrl": "https://…" }` → the client GETs that URL and decodes `TranscriptionResult`
(word-level segments; see `Transcription/`). Returning a `file://` URL will not work —
`URLSession.data(from:)` is used and the status code is checked.

## Gateway side, in one paragraph

`palmier-gateway` holds no capabilities. `translate.mjs` turns `orca` capability envelopes
into `CatalogEntry` — one entry per **engine alias**, so the model `id` the client submits
is an alias, resolved back to (capability, engine) at `/api/generate`. Five capabilities are
exposed: `video-generation`, `image-generation`, `text-to-speech`, `audio-generation`,
`image-upscale`. `paidOnly` is `engine.billing === 'metered'`; every pricing field is
deliberately omitted so `CostEstimator` returns nil and the UI shows no estimate rather than
a fabricated zero. `/api/generate` maps the client's flat params onto the capability's
declared CLI params (`PARAM_MAP`), extracts staged `storageId`s back out of
`/files/staging/…` URLs, and queues through `orca-gateway-core`'s job store
(concurrency 2). Terminal jobs are persisted under `data/jobs/`; in-flight ones are not.

## Client ↔ gateway mismatches

Checked at `palmier-gateway@d96f448` against this branch. All four are gateway-side fixes —
the Swift is upstream and shouldn't move.

1. **Upscale toggles never apply.** Swift encodes `UpscaleSettings` as
   `{selections, numbers, toggles}`, so the flag arrives at
   `params.settings.toggles.noSharpen`. `PARAM_MAP.upscale` reads `p.settings?.noSharpen`,
   which is always `undefined` — "Skip sharpening" silently does nothing. Fix:
   `p.settings?.toggles?.noSharpen === true`.
2. **Image reference images are dropped.** `imageEntry` advertises
   `supportsImageReference: true`, so the UI lets the user attach one and Swift sends
   `imageURLs`. `PARAM_MAP.image` ignores it — the generation runs prompt-only and reports
   success. Either map it onto the capability (`image-edit` isn't exposed) or set
   `supportsImageReference: false`.
3. **Extra video reference images are dropped.** `PARAM_MAP.video` takes
   `referenceImageURLs[0]` only, while `maxReferenceImages` defaults to 4 when the envelope
   declares no cap. Slots 2–4 vanish without a warning.
4. **Audio `durationSeconds` is dropped.** Low impact today — `audioEntry` declares neither
   `durations` nor `durationRange`, so the UI has no duration control to send from. It
   becomes a real gap the moment either is published.

Also: the gateway's README documents `GATEWAY_CONCURRENCY`, but `orca-gateway-core` reads
`ORCA_GATEWAY_CONCURRENCY`.

## Routes the fork never calls

`GET /api/account`, `POST /api/uploads/ticket`, `POST /api/uploads/commit`, and
`POST /v1/agent/stream` are served but unused. `AccountService` short-circuits locally
instead of fetching an account, the agent keeps its BYO-key `AnthropicClient`, and
`LocalBackend.uploadReference` constructs `…/files/staging/{storageId}` itself rather than
committing. That last one is a coupling to watch: the URL shape is duplicated in
`LocalBackend.swift` and in `/api/uploads/commit`, and only `storageIdOf`'s regex in the
gateway keeps them honest.

## Behavioral differences worth knowing

- **No credits, no gating.** `remainingCredits` is `Int.max` and `isPaid` is true, so every
  paid-only model and every credit precheck passes. Cost accounting is the gateway's
  problem, or nobody's.
- **Polling, not subscription.** Job progress updates at 0.8 s instead of push. The
  publisher never completes on its own; consumers cancel at a terminal status. A job that
  never reaches `succeeded`/`failed` polls forever.
- **Catalog is a snapshot.** Cloud mode gets live catalog updates; local mode fetches once
  per launch (plus retries while failing). Restart the app after editing the gateway's
  model list.
- **Timer on the main runloop.** The polling `Timer.publish(on: .main)` fires on the main
  actor; decode happens on the URLSession queue. Fine at 0.8 s for a handful of jobs, but
  it is main-runloop-scheduled work — don't scale the job count without revisiting it.
- **No retry/backoff on job polls.** Transport errors map to `nil` and are retried at the
  next tick; a gateway that is down looks like a job stuck in its last known state.
- **A gateway restart strands in-flight jobs.** `orca-gateway-core` persists only terminal
  jobs (`data/jobs/*.json`); an in-flight one dies with the process, so the poll turns into
  a 404, the client decodes it to `nil`, and the UI shows "Generating…" forever. Finished
  jobs survive a restart and resolve correctly.
- **Errors are structured on the wire, flattened in the app.** The gateway returns
  `{"error": {"code", "message"}}`; the client shows the whole body inside
  `gateway HTTP 400: …`. Keep `message` short and human-readable.
- **Staged uploads are buffered in memory.** `express.raw({limit: '1024mb'})` holds the
  whole file before writing it — relevant when transcribing long source video.

## Dev signing (why `run-signed.sh` exists)

`swift run` ad-hoc-signs the binary and the code identifier changes each build, so the
Keychain "Always Allow" grant for the Claude API key never matches on relaunch.
`scripts/run-signed.sh` builds the same debug binary and re-signs it with a stable identity
and the fixed identifier `io.palmier.pro`, so the grant sticks. `scripts/bundle.sh` gains a
matching fallback: if the Developer ID release cert isn't in the keychain, it falls back to
the first `Apple Development:` cert instead of failing. Pin the cert by SHA-1 via
`SIGNING_IDENTITY` — names are ambiguous on machines with several certs.

## The other half of the fork: external media providers

Independent of the gateway, `fork/orca-studio` also adds `Sources/PalmierPro/MediaProviders/`
— an `AssetProvider` protocol with a static registry of localhost asset servers, a Sources
tab in the media panel with drag-to-timeline, and three MCP tools (`list_sources`,
`list_source_assets`, `import_source_asset`). Registered sources and their default ports
(all env-overridable):

| id | label | default | env |
| --- | --- | --- | --- |
| `downloads` | 下载素材 | `127.0.0.1:4617` | `DOWNLOADS_GALLERY_URL` |
| `projects` | 自制成片 | `127.0.0.1:4618` | `PROJECTS_GALLERY_URL` |
| `photos` | macOS Photos bridge | `127.0.0.1:5374` | `PHOTOS_BRIDGE_URL` |
| `jianying` | 剪映素材 | `127.0.0.1:5174` | `JIANYING_BRIDGE_URL` |
| `capcut` | CapCut 素材 | `127.0.0.1:5274` | `CAPCUT_BRIDGE_URL` |

These are *not* palmier-gateway and work in cloud mode too. Loopback imports are gated by
`AssetProviderRegistry.isRegisteredLoopback` — only host+port pairs of registered providers
are importable.

## Appendix — generation params by `kind`

```
video    prompt, duration, aspectRatio, resolution?, sourceVideoURL?,
         startFrameURL?, endFrameURL?, referenceImageURLs[]?, referenceVideoURLs[]?,
         referenceAudioURLs[]?, generateAudio
image    prompt, aspectRatio, resolution?, quality?, imageURLs[]?, numImages
audio    prompt, voice?, lyrics?, styleInstructions?, instrumental, durationSeconds?,
         videoURL?, sourceURL?, targetLanguage?, referenceImageURL?,
         referenceAudioURLs[]?, multilingual?
upscale  sourceURL, durationSeconds, sourceWidth?, sourceHeight?, sourceFPS?, settings
```

Arrays are omitted when empty; `?` fields are omitted when nil. Source of truth:
`Sources/PalmierPro/Generation/Catalog/{Video,Image,Audio,Upscale}ModelConfig.swift`.
