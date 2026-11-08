# Persistent storyboard review

`EditPlan.productionRun` owns run identity, phase, the prepared storyboard revision,
explicit approval, grouped comments, and source-inspection evidence. Plans still
own scripts, shots, section order, estimates, claims, and measured narration.
Storyboard cards are derived; no second authored script or timing model exists.

## Review flow

1. Create a plan with script beats, scene-to-beat links, selected visuals, and
   license/attribution lines. Imported selections retain those rights fields.
2. `plan_edit action=prepare_storyboard` prepares the persistent review.
3. `read_storyboard` returns cards, source/span revision keys, source conflicts,
   inspection evidence, and grouped blockers. The native Storyboard button opens
   a scene list with narration, purpose, rights, references, and a lazy source
   thumbnail. A source thumbnail is not a sequential preview or face certificate.
4. `review_storyboard_scene` records an inspection actually performed against
   that exact selection. Stills require complete still inspection; videos require
   continuous selected-span playback, including intended final framing. Provide
   reviewer identity, evidence, face findings, rights confirmation, and unresolved
   suspected-duplicate findings. Never fabricate those findings from metadata.
5. The user explicitly approves the complete current revision with
   `approve_storyboard`, optionally recording grouped editorial comments.
6. A managed plan's `apply_plan` checks current approval, inspection blockers,
   retained source uniqueness, and measured source bytes before assembly. Existing
   generic plans remain generic editing operations, not verified productions.

## Editing scenes

`revise_storyboard_scene` changes selected source-linked script beats and/or a
library visual as one undoable action. Beat IDs, purpose, and claim references stay
stable. A beat shared by several scenes remains one authored value; every dependent
card changes together. Omitting pronunciation wording clears that beat's override.
Replacement visuals require exact current library image/video IDs and explicit rights fields.
The complete proposed board is audited before mutation; a known duplicate refuses
the entire edit. Adjacent authored selections remain distinct uses; only timeline
audits coalesce uninterrupted editorial splits. Missing inspection evidence stays
a blocker, not implied approval.

`reorder_storyboard` supplies every current scene ID exactly once. It preserves
scene/beat IDs and durations, moving narration blocks and complete section ranges
with the requested scene sequence. The current operation requires contiguous,
non-overlapping scenes, complete one-scene ownership of narration, and contiguous
section membership. Shared beats, gaps, overlaps, partial or split sections are
refused rather than silently dropping or rearranging dependencies. Reordering
invalidates measured narration and approval; new speech must match the new order.

Native scene controls edit narration, pronunciation, source, source span, license,
and attribution. Move-earlier/later buttons use the same domain operation as MCP.
Changing a source clears copied rights in the draft, requiring an explicit review
of the replacement's rights. Draft controls do not mutate the plan until Save.
Narration-only edits remain available when a visual is missing. Invalid source
time text cannot submit an old numeric value, and unchanged drafts cannot submit.
External beat changes refresh draft wording even when pronunciation stays unchanged.

Unknown inputs, unavailable media, unresolved derivative lineage, absent rights,
unresolved claims, revealed faces, suspected duplicates, and incomplete inspection
block approval. Approval cannot waive these blockers. It is an attestation tied to
performed inspection, not an automated detector/perceptual-matching certificate.
Receipts never claim verified delivery.

## Revision and execution contracts

Revision digests are computed off-main over authored intent and selected source
identities. File paths and library display names do not bind approval, allowing
package relocation without silently changing the reviewed visual content. Script,
pronunciation, scene order, source span, rights, claims, or intended pacing changes
invalidate approval. Source-identity/configuration changes also produce stale
readback. Preparing a revised board retains only matching selection reviews.

Measured narration timing is derived and excluded from the storyboard intent key.
Resolving timing inside unchanged intent does not request another approval.
Changing narration language or start intent does. Future voice/graphic contracts
must extend the same intent key, not add another approval owner.

Preparation, inspection, approval, revocation, and cancellation use shared plan
mutation/undo and existing project checkpoints. Repeated unchanged operations
are no-ops. Approval is one undo action. Plans persist run state through the
existing plan package codec; malformed approval records are rejected.

Audits and digest/receipt encoding execute off-main. Byte verification uses the
shared serial, metadata-validated identity service. Every await revalidates plan,
timeline, project, manifest, and relevant source identity before mutation. Scene
inspection prepares its updated report before committing. Native tasks cancel on
selection change/dismissal and reject old completions. Thumbnail work is lazy for
the selected scene; video capture uses the existing bounded frame-capture service.

## Remaining work

This slice is not the complete production coordinator. Final narration generation,
graphics jobs, lower-level placement/export protection, actual-output face/framing
review, semantic graphics, sequential animatic, dependent revisions, recovery, and
verified delivery remain roadmap work.
The native panel records review; it does not itself play a selected video span.
Users must inspect it using a supported playback path before attesting.

## Manual UI verification — pending user confirmation

- Setup: open an isolated project containing ready licensed stills/video and a
  plan with source-linked script beats. Open Storyboard from the title bar.
- Select each scene. Expect correct narration, purpose, rights, input ID, and
  source span. Missing/corrupt preview remains explicit, never marked inspected.
- Prepare the board. Approval stays disabled until claims and each full-selection
  inspection are resolved. A duplicate copied source blocks the entire board.
- Inspect the complete source and intended framing, record actual evidence, and
  approve once. Expect no per-shot approval prompts and one undo action.
- Change source, script, pronunciation, license, or pacing. Expect stale approval;
  prepare again and review changed selections. Unchanged selection evidence stays.
- Edit a beat shared by two cards; both must display the changed wording. Save
  narration and replacement together, then undo once; both restore exactly.
- Move a scene earlier/later. Expect its narration and complete section to follow;
  gaps, shared beats, split sections, and reused replacement sources are refused
  without edits or empty undo steps. Repeated unchanged requests are no-ops.
- Resolve narration timing without changing intent. Expect approval retained.
- Exercise Tab/focus, keyboard scene selection, Escape dismissal, undo/redo,
  switching plans while loading, missing assets, and empty/disabled states.
- Save, autosave, Save As, close/reopen, then inspect run/review state and source
  freshness. Cancel/reprepare explicitly; canceled approval cannot assemble.
- Play assembled output with sound and verify actual framing. This remains a
  separate human check; source thumbnails and unit tests cannot prove it.
