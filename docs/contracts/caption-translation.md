# Caption translation pipeline

`translate_captions` carries script beats into multilingual captions styled by the gallery, aligned to narration timing, through a review stage before anything lands on the timeline.

## Flow

1. **Translate** (optional dict override): `action: translate` with `targetLanguage`, sourced from `planId` (measured narration anchors), explicit `beats` (with frames or seconds), or existing timeline captions. Unknown styles refuse with the option list.
2. **Read**: `action: read` with `jobId` returns the whole job.
3. **Review**: `action: review` edits text/timing or approves one segment; `approve_all` approves the rest. Status moves translated → partially_approved → approved.
4. **Apply**: `action: apply` inserts approved segments as one caption group on a new track, preserving undo; the receipt reports track, clip ids, and provenance.

## Translation honesty

The app embeds a phrasebook for common caption phrases (welcome, follow/subscribe, summary, highlight, …); longer lines and non-covered phrases fall back to partial replacement and identity passthrough. For anything beyond the phrasebook, the agent passes `customTranslations` keyed by beatId or source text. The review job keeps source and translated text side by side so the user can see what was actually translated.

## Verification

`CaptionTranslationToolTests` (5 suites) covers translate/review/edit/approve/apply, narration-anchored sync, unknown style refusal, already-applied and no-approved-segment refusals, and single-undo commit. The Agent Instructions direct the agent to offer this pipeline for translated-caption requests.
