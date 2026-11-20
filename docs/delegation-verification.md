# Delegation verification protocol

Implemented code cannot prove itself in the installed app: model latency, UI
focus, Save As, and quit require a human against the real app and a real
provider. This protocol defines the evidence to record; unconfirmed steps are
unverified, not passed.

## Real-provider latency

1. Sign in with the provider account under test and select the model.
2. In an isolated project with supplied evidence, ask for two independent scene
   drafts in one request (e.g. draft narration for two scenes).
3. Console/Console.app (`subsystem: io.compositor.pro`, category `agent`):
   record `delegation prepared <n>/<n> tasks in <ms>ms`. Record the acceptance
   turn's `total` and `firstOutput` from the chat-stream entry as sequential
   comparison. Three repeats; report each median, never a single run.
4. A sequential comparison turn (ask for one scene at a time) gives the baseline
   with the same model. Report delegated vs sequential medians side by side.

Pass: delegated median < sequential median with receipts complete and no
production-gate bypass. Fail/timeout routes are acceptable if they produce
`refused`/`fallback_required`, never silent success.

## Installed-app UI and lifecycle checks

Run inside the installed app (not a debug scratch build):

- Parallel drafting: two independent drafts arrive in order; parent applies
  with one undo action per coherent edit; no duplicate commits.
- Cancel during drafting; switch chats; start a new request. No late draft in
  the new chat; streaming state of the new run is intact.
- Edit storyboard/timeline/source identity/model mid-run → stale refusal, then
  fresh preparation required.
- Unsupported/refusing model or forced timeouts → finite retries, then normal
  parent execution of unfinished permitted work; no provider swap.
- Save As or close during drafting → admitted work drains before the save
  snapshot; reopen and verify plan timing, chat, and undo. Refused requests add
  no undo step.
- Confirm rights, revealed-face, uniqueness, and storyboard-approval blockers
  still gate assembly/delivery after these interactions.

Record the app version, model, each step's observed result, and files changed.
Verify signature with `codesign -dv --verbose=4 /Applications/CompositorPro.app`
only when signing is available.

## Current state (honest)

- Gate-proven overlap/fallback/undo/cancel in automated tests; production join
  exists in `AgentStreamOperation.join()`.
- Real-provider latency and installed-app checks remain user verification.
  Aggregate latency distributions across repeated briefs before claiming speed.
