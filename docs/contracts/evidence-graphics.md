# Sourced Data and Evidence Scenes

`build_graphic_scene` creates typed, sourced graphic video scenes (`numeric_comparison`, `source_card`, `comparison_chart`, and `policy_timeline`) from structured inputs. The graphic specification is the source of truth, backed by claim provenance from the source ledger; the Lottie vector animation and baked ProRes 4444 video are deterministic derived outputs.

## Contract

### 1. Typed Graphic Family
- **`numeric_comparison`**: Compares two or more numerical data items (e.g. market share, output, investment). Supports optional delta calculation and delta labels, automatic unit compatibility enforcement, and visual comparison layouts.
- **`source_card`**: Displays provenance for a key claim or quote, including publication title, author, URL or document reference, accessed date, quotation or paraphrase, and linked claim IDs. Rejects fabricated or incomplete provenance.
- **`comparison_chart`**: Renders multi-series bar or line charts with deterministic axes, tick mark calculations, labels, and scale intervals.
- **`policy_timeline`**: Renders dated chronological events (e.g. regulatory milestones, policy announcements, roadmaps) with strict chronological order validation (ISO 8601 / `YYYY-MM-DD` / `YYYY-MM` / `YYYY`).

### 2. Validation & Determinism
- **Units & Bounds**: Numeric values must be finite numbers; negative values, out-of-bounds scales, and incompatible units (e.g. comparing USD with Percent) are rejected before mutation.
- **Attribution & Provenance**: Source cards require authentic author, accessed date, and either a valid URL or document reference (not both, not neither).
- **Chronology**: Policy timelines reject events with decreasing or unordered dates.
- **Deterministic Layouts & Motion**: Axis bounds, tick intervals, bar geometry, text layouts, card containers, and reveal animations (staggered opacities and hold frames) are generated algorithmically without requiring Agent roundtrips for every keyframe.

### 3. Display and Narration Agreement
`EvidenceGraphicNarrationValidator` enforces agreement between on-screen graphics, accompanying script beats, and source claims:
- **GDP vs GDP Per Capita**: Prevents displaying total GDP when narration asserts per-capita income, and vice versa.
- **Nominal vs Adjusted / Real**: Rejects graphics displaying nominal values when narration claims inflation-adjusted or real figures.
- **Announced vs Realized Investment**: Rejects graphics displaying announced pledges or pipeline targets when narration asserts realized, actual, or disbursed investment.
- **Quantitative Claim Alignment**: Ensures numerical values and units in the graphic exactly match the cited quantitative claims in the plan's `sourceLedger`.

### 4. Synchronization & Stale Data Prevention
`EditPlan.updateClaimAndSyncDependents(claimId:newValue:newUnit:narrationUpdates:)`:
- Atomically updates claims in the `sourceLedger` and marks the status as `.unresolved` for re-review.
- Synchronizes all dependent narration beats with the new value, ensuring old figures are not left behind in the script.
- Returns a structured report detailing all dependent shots, sections, and beats affected by the value correction.

### 5. Media Pipeline & Undo
- Generates Bodymovin v5.7.0 JSON animations with shape layers, text cards, and animated opacity windows.
- Bakes alpha ProRes 4444 (`.mov`) video locally via `LottieVideoGenerator`.
- Installs media assets into the live project package via `ProjectPackageCoordinator.commitStagedProjectMedia` under a scoped mutation lease.
- Optionally places the graphic on the timeline with `withTimelineSwap`, providing native undo that fully removes the placed clip without leaving residual state.

## Limits
- Complex multi-axis charts (logarithmic scales, dual y-axes) are outside the current family scope.
- Sourced graphic animation is currently rendered as baked ProRes 4444 video; live editable vector shapes on the canvas are non-goals for this slice.

## Verification
- Unit test suites in `Tests/CompositorProTests/Agent/EvidenceGraphicTests.swift`:
  - `EvidenceGraphicValidationTests`: Validates bounds, compatible units, provenance requirements, and timeline chronology.
  - `EvidenceGraphicNarrationAgreementTests`: Verifies detection of GDP vs GDP per capita, nominal vs adjusted, announced vs realized, and mismatched claim values.
  - `EvidenceGraphicLottieTests`: Verifies valid Bodymovin JSON generation and signature checks across all 4 graphic family members.
  - `EvidenceGraphicMCPTests`: Verifies tool execution, media registration, timeline placement, undo behavior, and dependent claim synchronization.
- Build & Sanitizer checks:
  - `swift test --filter 'EvidenceGraphic'` passed 11 tests across 4 suites.
  - `swift test --sanitize thread --filter 'EvidenceGraphic'` passed all 11 tests with zero data races.
  - `swift build --traits BundledSpeech` succeeded cleanly.
  - `scripts/localization/sync.sh` validated all 1,424 source strings.

