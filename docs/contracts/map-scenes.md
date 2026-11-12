# Geographic map scenes

`build_map_scene` turns a supplied place/connection/camera specification into a baked video scene. The spec is the editorial source of truth; the Lottie JSON and baked mov are derived outputs.

## Contract

- `MalaysiaPlaceCatalog` owns 12 Peninsular places (5 island) with approximate WGS-84 centroids (`MalaysiaPlaceCatalog.datasetNote`). Unknown/blank names and duplicates refuse; aliases (`George Town`, `KL`, `JB`, `PTP`) resolve to canonical entries. East Malaysia and survey naming are non-goals.
- `MapProjection` is the single equirectangular projection: longitude degrees scale by `cos(mean latitude)`, latitude degrees map directly. `screen(point, camera, frame)` is the shared oracle: a layer child at anchor + plane renders at `groupPosition + plane * zoom`.
- Pins, route strokes, and text labels live in one Lottie shape layer plus parented text layers sharing one keyframed transform, so labels stay attached during camera moves. Reveal frames hide shapes via group opacity keys and labels via layer windows.
- Connections are `illustrative` unless `kind: sourced` with a non-empty claimId list; claim IDs are validated for shape only (ledger binding is task 3/10).
- The tool validates the full spec before mutation, bakes off the staged JSON through `LottieVideoGenerator`, and installs the mov via `commitStagedProjectMedia` inside a package mutation lease. Refusals add no asset, clip, or undo step. The receipt returns the spec, digest, and catalog coordinates.

## Limits

- No region polygons (no sourced dataset in scope), no plan/ledger binding, no plan-side spec persistence; corrections regenerate a new asset.
- Catalog coordinates are centroids, not boundary-accurate; `deliveryVerified` and uniqueness behavior are unchanged from tasks 5b/10.
- Human playback attachment across reveals remains manual.

## Verification

Focused `MapScene|ToolDefinition|ToolDiscovery|ExplainerContractsMCP|ComposeImage|Storyboard|VisualUniqueness|ProductionExportGate|Lottie` passed 127 tests in 20 suites. Projection oracle, catalog ambiguity, sourced-link evidence, and invalid frame/zoom refusals are unit-covered. The attachment test renders the same spec at first/last camera keys and asserts bright label pixels follow predicted screen positions. MCP tests verify library registration, spec receipt, placement duration, undo, and unknown-place refusal. Full `swift test` passed 2,574 tests in 377 suites (with concurrent unrelated work temporarily absent for that run). TSan was not completed — blocked by another worker's in-flight broken files and a SIGKILL, with no race diagnostics observed. A staged-only snapshot build failed on `ExportQueue.waitForCompletion` — `HEAD` pairs the finishing worker's `ToolExecutor+Export` caller with a missing `ExportQueue` definition and cannot build standalone; no standalone full pass is claimed.
