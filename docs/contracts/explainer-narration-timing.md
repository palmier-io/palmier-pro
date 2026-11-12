# Measured narration timing

Edit plans own ordered `scriptBeats`: stable `beatId`, paragraph `text`, editorial `purpose`, optional factual `claimIds`, and optional pronunciation wording `spokenText`. Pronunciation wording replaces the paragraph for speech/alignment, not its displayed script. Claim-dependency receipts include script beats and scenes linked to those beats.

## Prepare narration

1. Import recorded narration or generate the ordered paragraphs through the existing `generate_speech` operation. Speak `spokenText` when present, otherwise `text`.
2. Attach the ready audio with `plan.narration` or `patch.narration`: `mediaRef`, project `startFrame`, optional local transcription `language`.
3. Call `plan_edit` with `action:"measure_narration"` and `planId`.

Measurement uses the whole audio source at normal speed. It asynchronously loads exact AVFoundation duration, runs local transcription, and aligns ordered script tokens to word timestamps. It does not synthesize, place clips, spend credits, or automatically shorten the script. Local model availability/install failures remain errors.

Matching ignores case and surrounding punctuation. Internal numeric punctuation remains significant. Every spoken token must match in order, every word needs valid ordered times, and all times must lie within measured duration. Missing, different, overlapping, or malformed word timestamps return `aligned:false`, all `unresolvedBeatIds`, and no partial anchors. Recognition is conservative, not forced alignment; languages, acronyms, numeric readings, and alternative spellings may need explicit pronunciation wording or corrected narration. Guessed timing never becomes measured timing.

## Scene timing

Sections and shots may cite `narrationLink`:

```json
{
  "firstBeatId": "first-beat",
  "lastBeatId": "last-beat",
  "minimumHoldSeconds": 1
}
```

Linked authored `startFrame`/`endFrame` values are storyboard estimates. One shared resolver derives `resolvedTiming` for readback, readiness, and assembly:

- Start: first covered beat's speech start; the first script beat includes leading silence from source time zero.
- End: next beat's speech start; the last beat includes trailing audio through the last complete project frame.
- Reveal: scene start. Hold: the entire resolved scene range. Sub-scene graphic reveals remain future semantic-graphics work.
- Interior boundaries round exact media time to nearest project frame, with half values away from zero. Final duration rounds down, avoiding playback past source end. Adjacent linked beats share one boundary.
- Minimum hold defaults to one second, accepts 1–60 seconds, and rounds up to complete frames. Short ranges and timeline overflow block assembly rather than stretching narration.

Unlinked scenes retain authored frame timing. Source spans must still match resolved shot duration through existing placement validation; measurement never silently changes selected footage spans.

`apply_plan(commit:true)` assembles resolved shots and attached narration in one existing undo action. Explicit shot tracks also require an existing compatible audio track. Readiness requires reviewed referenced facts, fully aligned narration, unchanged narration bytes, matching timeline geometry, and valid placement. Repeated applied plans never assemble again.

## Ownership and invalidation

The plan owns script/source configuration and a narration revision. Measured timing is a derived artifact containing that revision, source SHA-256, exact rational duration, and beat anchors. Changing text, pronunciation, purpose, claim links, source identity, language, or placement invalidates timing. Scene ranges are computed from current links; there is no second mutable timing owner.

Preparation runs through one serial service, with structured awaits and cooperative cancellation. File hashing, decoding, and recognition stay off-main. Source bytes are checked before and after recognition and before assembly. Identical completed timing is reused without recognition; unresolved timing may be retried. The service retains at most one successful result, keyed by source configuration, script beats, revision, and fingerprint; a new successful result replaces it. Revalidation checks the plan, editor binding, project location, active timeline snapshot, source URL, and media readiness before commit. Failed, canceled, stale, and unchanged requests add no empty undo action. Measurements and authored changes undo independently and persist in existing `plans.json` snapshots.

## Verification scope

Focused unit/MCP tests use generated local PCM audio and deterministic injected transcript records, not network services or production models. They prove actual duration loading, alignment validation, revision invalidation, measured placement, source-change refusal, package readback, no-ops, and undo. Deterministic lifecycle gates cover cancellation and stale completion. They do not certify recognition accuracy or audible speech quality.

Automatic paragraph regeneration, production-run resumption, final voice approval, word/graphic reveal choreography, and storyboard UI remain later roadmap layers. Manual verification: on an isolated project, generate/import real narration, attach it to matching script beats, measure, inspect unresolved words if present, assemble, listen around beat boundaries, and confirm one undo restores the pre-assembly timeline. Change pronunciation, verify readiness blocks, replace narration, then measure again. Confirm localized Undo “Measure Narration,” missing-media refusal, and close/reopen persistence. No manual UI pass claimed.
