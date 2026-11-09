# Human confirmation checklist

Code-verified pieces still need a person in the installed app. Mark each line
**Pass / Fail**, note the app version + model, and record anything the app did
that the checklist didn't predict. A Fail blocks the related gate; unrun
checklists are unverified, not passed.

## A. Caption styles (item 15)

- [ ] Open a project → Captions panel. Gallery shows three groups with rendered previews.
- [ ] Pick a Loud look (e.g. Neon). Generate captions → title/annotations carry the style.
- [ ] Pick an On-a-box look (e.g. Boxed). Regenerate → box treatment appears.
- [ ] Pick a Calm look (e.g. Clean). Generate again → minimal, no animation.
- [ ] Keyboard focus lands on the selected cell; Escape dismisses without changing the selection.
- [ ] Close/reopen the project → the gallery selection persists.
- [ ] Old captions keep their previous style (no retroactive restyle).

## B. Map scenes (task 6)

- [ ] `build_map_scene` a Penang→Kulim locator map in a disposable project.
- [ ] Play it end to end: pins stay anchored, labels track the camera through zooms, no drift.
- [ ] Rebuild with a corrected place name; only the new scene regenerates.

## C. Delegation latency + lifecycle (`docs/delegation-verification.md`)

- [ ] Two independent scene drafts in one request; three latency repeats recorded.
- [ ] Cancel, chat switch, stale-edit rejection, and refusal/fallback behavior observed.
- [ ] Save As / close during drafting drains before the snapshot; reopen verifies undo.

## D. Storyboard gates (task 5 + Gate A)

- [ ] Unapproved/stale storyboard blocks assembly; approval requires exact revision.
- [ ] Duplicate visual use is refused at approval, assembly, and delivery (incl. copies, alternate renditions, nested timelines).
- [ ] Focused panel review: narration, purpose, sources, rights, blockers, thumbnails, undo.

## E. Signed release

- [ ] `./scripts/preflight-signing.sh` reports ready.
- [ ] After signing: `codesign -dv` shows Developer ID authority and the install replaces `/Applications/CompositorPro.app` intact.
