# Stock-source pagination and exclusions

## Scope

Stock search retrieves candidates only. Manifest-wide source aliases now drive both retrieval exclusions and the existing uniqueness audit. This change does not provision providers, download media, select replacements, or establish production readiness. No paid services or live provider searches were used.

## API contract

- `StockMediaQuery` retains `text`, `kind`, `orientation`, `maxDurationSeconds: Int?`, and `limit`. It adds `page: Int = 1` and `excludedSourceIds: Set<String> = []`.
- `StockMediaProvider.search(_:) async throws -> StockMediaPage` replaces the array return type. A page contains `hits: [StockMediaHit]`, `nextPage: Int?`, and `totalResults: Int?`.
- `StockMediaSearch.collect(_:providers:)` keeps `(hits, outcomes, totals, query)`. `search(_:providers:)` keeps `StockMediaResult`. Both accept an injected `[any StockMediaProvider]`; defaults remain Openverse, Pexels, Pixabay, in that order.
- Provider outcomes add `pagesFetched`, `exhausted`, `nextPage`, and `totalResults` to their receipts. Counts describe unique eligible candidates fetched from that provider, before the aggregate limit, not API totals.
- `totals` contains one latest reported total per provider that supplied a total, including providers that subsequently failed. Aggregate `totalResults` retains the maximum-reported-total convention; it is not a sum, an eligible-result count, or a deduplicated inventory.

Query text is trimmed and must be nonempty. Limits must be `1...50`; starting pages must be `1...500`. Invalid values are refused, never clamped. Duration is an integer, so non-finite values cannot enter this typed API; when supplied it must be positive and applies only to audio or video. Orientation must be landscape, portrait, or square and cannot apply to audio. Duration/orientation filtering excludes candidates with missing required metadata.

Internal stock exclusions contain exact `stock:<provider>:<assetId>` identifiers without a count cap: manifest alias expansion may legitimately exceed the tool's explicit input limit. Each stock identifier has at most 256 UTF-8 bytes, with a lowercase ASCII alphanumeric provider token allowing hyphens/underscores, and an ASCII alphanumeric asset token allowing hyphens/underscores/dots. Both tokens start with an alphanumeric character. Whitespace, extra colons, paths, Unicode stock tokens, empty tokens, and media/hash aliases are refused by the stock query. Existing provider asset IDs are unchanged: for example, `stock:pixabay:pixabay-video-125`.

Remote exclusion and deduplication use `hit.origin.sourceId`, never the download URL. Alternate renditions of the same source remain one candidate; distinct canonical sources sharing a URL remain distinct. Expansion of local media/hash aliases into remote canonical IDs belongs to the caller.

## Shot-candidate integration

`find_shot_candidates` accepts at most 256 distinct explicit `excludedSourceIds`: canonical `media:<mediaRef>`, valid `sha256:<hash>`, or stock IDs. An optional existing `planId` adds all selected media references. `VisualSourceAliases` connects valid retained hashes and stock origins across the entire manifest, including unselected bridge entries; each connected component expands once. Explicit input bounds never truncate derived aliases. Unknown identities produce unresolved blockers, not wildcard bans. Retained identity is not fresh-byte or perceptual verification.

Eligible local assets are filtered before visual/transcript retrieval. Refill removes every alias of already represented sources, not merely the returned trim. Represented local sources also exclude remote equivalents before bounded pagination. Final ranking prefers usable local evidence and returns one candidate per known source identity. Different trims remain stable candidate IDs, but do not occupy separate shortlist slots.

`ToolExecutor` owns an immutable provider dependency shared by direct and MCP dispatch. Snapshot completion revalidates editor binding, project identity/URL, timeline identity, plan values, media metadata, manifest, and source URLs. Cancellation or stale completion does not publish a partial receipt. Successful receipts are explicitly read-only (`noOp: true`), preserve provider continuation outcomes, and never retarget the plan, approve a storyboard, download, place, persist, or open an undo action.

## Retrieval and failure semantics

At most two provider tasks run concurrently. Each provider follows only explicit API continuation metadata, fetching at most three successful pages while seeking `limit` unique eligible candidates. The final aggregate interleaves candidates in stable provider order, one eligible candidate per provider per round, then applies the limit. Filtering and deduplication happen before this limit.

Empty or fully filtered pages do not imply exhaustion. Only a successful page with no continuation sets `exhausted = true`. Reaching the candidate target, three-page budget, or supported page bound preserves `nextPage` and leaves `exhausted = false`. A reported continuation beyond page 500 is retained but not fetched; such a starting page remains invalid.

An HTTP denial, missing key, rate limit, malformed response, or other failure stops that provider without retry. Earlier hits, reported totals, successful page count, and the failed continuation page remain visible. Unsupported, unavailable, failed, rate-limited, successful-but-incomplete, and exhausted outcomes stay distinct. Cancellation is checked before requests and after every provider await and prevents partial-success receipts or newly queued provider work. Empty video search retains its existing no-usable-results refusal only when every supported provider succeeded and explicitly exhausted; `collect` always exposes empty results and outcomes.

## Official pagination metadata

Public documentation consulted for this implementation:

- [Pixabay API](https://pixabay.com/api/docs/): request `page` and `per_page` (`3...200`). The adapter requests `max(3, limit * 2)` rows. Continuation is determined from the requested page/page size and `totalHits`, the number accessible through the API, not global `total` or filtered hit count. The documented default accessible inventory is at most 500 results per query.
- [Pexels API](https://www.pexels.com/api/documentation/): request `page` and `per_page` (maximum 80). Video search uses the currently documented `/v1/videos/search`; photo search uses `/v1/search`. The old `/videos/search` endpoint is not retained as a fallback. The adapter requests `min(limit * 2, 80)` rows, reads `total_results`, and parses the actual page number from optional `next_page`. It does not assume consecutive pages. Continuation URLs must retain the HTTPS host and endpoint; only their page number is reused, never arbitrary URLs or credentials.
- [Openverse public OpenAPI schema](https://api.openverse.org/v1/schema/?format=json): current image/audio search reports `page`, `page_count`, and `result_count`, rather than a `next` URL. The adapter uses this official continuation boundary and requests `page` plus `page_size = min(limit * 2, 20)` for anonymous access. Anonymous pagination requires `page * page_size <= 240`; with a page size of 20, page 12 is allowed and page 13 is refused before HTTP. Refusal uses `invalidQuery(field: "openversePaginationDepth")` and produces a failed provider outcome, not a missing-key outcome. Previously fetched results and continuation remain visible; no authentication headers or credentials are added. The adapter does not infer exhaustion from filtered rows or pretend the reported result inventory is fully accessible. Audio duration filtering compares original milliseconds before rounding positive durations up to integer seconds for receipts, so subsecond audio remains eligible and no duration addition can overflow.

Provider row-size bounds are request sizing, not silent adjustment of the user's validated result limit. A small Openverse page and a three-page budget can legitimately yield fewer than 50 eligible hits; the receipt retains any remaining continuation.

## Verification and remaining work

Offline tests cover canonical exclusions, alternate rendition URLs, filtering before limits, stable interleaving, two-worker admission, explicit skipped-page continuation, quotas, exhaustion, partial failures, denial/rate-limit no-retry behavior, deterministic cancellation gates, strict input bounds, provider page sizing, and URLProtocol-backed pagination response fixtures. Openverse coverage includes anonymous-depth refusal before HTTP, continuation preservation at the depth boundary, and parameterized subsecond/exact-duration limits with rounded-up receipts. Existing stock-provider fixtures include official pagination fields.

Earlier provider/domain-only verification passed `swift build`, 96 focused tests in 7 suites, and the same 96 tests with Thread Sanitizer. That snapshot predates consumer integration, distinct-root alias expansion, and removal of the derived exclusion cap; final-source proof is below.

Final integrated frozen source passed:

- `swift build`.
- `swift test --filter 'StockMedia|StockProviderPagination|VisualSourceAliases|ShotCandidate|VisualUniqueness|AgentActivityHighlight'`: 126 tests in 11 suites.
- `swift test`: 2,353 tests in 347 suites.
- `swift test --sanitize thread --filter 'StockMedia|StockProviderPagination|VisualSourceAliases|ShotCandidate|VisualUniqueness|AgentActivityHighlight|UndoTool|StoryboardMCP'`: 145 tests in 13 suites, no reported races.

This snapshot contains the committed save/preview/delegation foundations and deterministic activity-expiry slice, but excludes unrelated finishing, credential, package-lifecycle, and subsequent narration work. Earlier full-suite routing/activity failures remain recorded in `todo.md`; a passing run does not prove unrelated routing tests can never recur.

Actual in-memory MCP transport exercises normal tool discovery and dispatch, invalid explicit inputs, manifest bridges, bounded remote pagination, continuation receipts, repeated requests, and independent plan/inventory/timeline readback plus empty undo. Deterministic provider gates prove client cancellation reaches the provider and stale project, plan, identity, URL, or executor-binding completion is rejected. Rebinding uses `bindProject(second)` during retrieval, not `manage_project open/create`. A 257-stock-alias MCP regression fails when the original internal 256-ID cap is restored and passes with complete derived exclusions. No live provider/account or native UI checks were performed.

Manual quality check: use an isolated project and representative briefs with configured providers, assign a source to a plan, request alternatives repeatedly, inspect actual downloaded spans and provenance, and confirm no selected-source alias returns. Compare relevance, usable formats, attribution completeness, requests, latency, and overlap across successful outputs. Do not use thumbnails or search receipts as content, face, rights, or final-delivery verification.

## Rendition dimension validation

Pexels and Pixabay rank only renditions with positive dimensions and a representable integer pixel count. Shared `StockMediaDimensions` validates multiplication before ranking; zero, negative, missing, or overflowing dimensions make a rendition ineligible. Invalid preferred files cannot crowd out valid alternatives. Existing HD/medium preference and size ranking remain unchanged. A representable maximum pixel count is retained without clamping; this is catalog arithmetic validation, not a promise that such dimensions can be decoded or exported.

The original dimension regression run aborted with signal 5 on a matrix including `Int.max × 2`. Fixed frozen source passed `swift build`, `swift test --filter 'StockMedia|StockProviderPagination|ShotCandidateExclusionMCP|ShotCandidateRemoteExclusion'` (68 tests in 5 suites), full `swift test` (2,356 tests in 347 suites), and the same focused filter with `--sanitize thread` (68 tests, no reported races). Coverage preserves existing HD/medium selection and proves invalid preferred/fallback renditions are skipped without clamping valid maximum arithmetic. This follow-up still excludes active package/narration work and live provider or installed-app verification.

Measured live search quality, multi-query diversity, real account quotas, denial/rate-limit behavior against providers, and production readiness remain pending. Provider caching/compliance and account-specific access limits also need separate verification; for example, Pixabay's public documentation requires 24-hour request caching, which this change does not implement. No readiness or live-quality claim is made.
