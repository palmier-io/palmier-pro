# Production export uniqueness gate

Video delivery (`export_project` mode=video) of a timeline carrying an active managed production re-audits the **current** output snapshot with `VisualUniqueness.audit` before queueing. Timelines without a production run, canceled runs, and edit-exchange modes (`xml`, `fcpxml`, `compositor` / legacy `palmier`) keep the general-editing contract: repeating media is allowed in experiments and interchange files.

The audit covers retained content identities and provider source aliases across nested carriers, overlays, and coalesced continuous splits. Any conflict or unresolved identity/lineage refuses delivery with counts and the action `replace_repeated_source`. The gate compares the audited snapshot and media manifest after the off-main audit; timeline or media changes during review throw instead of enqueueing stale state. Refusal adds no export job, timeline edit, or undo action.

`deliveryVerified` remains false in all receipts: the audit does not rehash bytes for freshness, run perceptual similarity, or inspect faces. Storyboard approval, plan assembly, scene revision, and this delivery gate share the same `VisualUniqueness` occurrence calculation; approval/assembly already refuse `repeated_visual_sources` and `unresolved_visual_identity`.

## Verification

`ProductionExportGateTests` (4 tests) cover duplicate refusal with unchanged timeline/undo, unique delivery, canceled-run bypass, and XML bypass. Focused suite (`ProductionExportGateTests|Storyboard|VisualUniqueness|ExportProject|PlanEditToolTests|QCTimelineToolTests|ExplainerContractsMCPTests|MediaInputIdentity`) passed 140 tests in 17 suites; TSan focused passed 93 in 10 suites with no races; full working-tree `swift test` passed 2,566 tests in 374 suites (including unrelated dirty finishing changes). Staged-only snapshot build is blocked by pre-existing dirty `ExportQueue.waitForCompletion` that HEAD lacks and the finishing worker owns — not by this slice — so no standalone full pass is claimed. Human UI playback, real-stock duplicates, and face/perceptual inspection remain manual.
