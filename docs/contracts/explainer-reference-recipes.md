# Reference recipes

`plan_edit` accepts externally prepared reference analysis. It does not fetch a reference URL or infer its recipe automatically. The Agent authors the chapter/scene outline using the supplied observations; the app validates and persists it with the existing edit plan.

## Handoff

Provide `plan.referenceRecipe` when creating a plan, or `patch.referenceRecipe` to replace it:

- `title`, `sourceURL`: reference identity; URL must use HTTPS.
- `sourceDurationSeconds`: optional positive finite reference runtime. Output runtime remains the plan's authored frame ranges.
- `coverage`: unique inspection modes actually used: `captions`, `stills`, `motion`, `audio`.
- `limitations`: required statement of what inspection cannot establish.
- `cues`: 1–128 editorial observations, each with stable `cueId`, `kind`, `evidence`, `observation`, and transferable `editorialRule`.

Cue kinds: `narrativeArc`, `sceneFamily`, `typography`, `geography`, `evidenceTreatment`, `pacing`, `motion`, `audio`. Evidence: `observed`, `inferred`, `unverified`. Observed cues require paired `startSeconds`/`endSeconds` source timestamps. Observed motion/audio also require the corresponding inspection coverage. Timestamps cannot exceed a known reference duration.

These classifications record the supplied analysis; they do not independently certify its truth. Do not copy narration, branding, assets, sponsorship, or voice identity. Transfer explaining principles instead.

## Outline rationale

Sections and shots accept `referenceUse`:

```json
{
  "cueIds": ["regional-context"],
  "rationale": "Show where the industrial dependency originates before explaining its effects."
}
```

Every cited ID must exist in the same plan's recipe. IDs must be unique within the use; rationale must be non-empty. Recipe replacement and dependent outline changes are validated atomically. Removing a cited cue without replacing its uses fails without changing the plan or undo history.

Single-plan `plan_edit(action:"read")` returns the recipe, limitations, chapter/shot rationale, and authored output timing. Repeating an unchanged update is a no-op; one changed update undoes as one action. Existing package snapshots persist the recipe in `plans.json`; no separate recipe store exists.

## Verification

`ReferenceRecipeTests` covers malformed handoffs and broken citations. `ReferenceRecipeMCPTests` verifies discovery, a 90-second outline derived from a 21-minute reference, chapter/scene rationale, package readback, invalid replacement, unknown-field refusal, normalized/repeated no-ops, and undo through MCP.

Storyboard UI, production approval, factual source/claim validation, and automatic reference acquisition are separate roadmap tasks, not supplied by reference recipes.
