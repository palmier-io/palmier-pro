# Parallel Agent preparation

The in-app Agent exposes `delegate_work` for independent text preparation. The
parent gathers relevant script, evidence, stable IDs, and constraints, then submits
one batch of tasks with unique `id`, `objective`, and immutable `context` fields.
Independent scene drafts and supplied-evidence reviews should run in parallel by
default. Dependent edits remain sequential.

## Ownership and limits

One `AgentDelegation` actor belongs to each parent run. At most two children run
concurrently, with at most eight tasks per batch. Each child gets a private
conversation, span, and message identity, retaining the parent trace/project
identity. Children use the selected parent's client and model; there is no implicit
provider/model substitution or credential content in child transcripts.

Each child receives only task text and inherited production constraints. Its tool
catalog is empty, and any returned tool call is rejected. Children cannot read
the editor, mutate projects, approve a storyboard, attest to unperformed visual
inspection, import/generate media, spend generation credits, undo, export, or spawn
more children. Results are drafts, not verified facts or proof of applied edits.
Normal model requests use the existing provider's billing; this is not free
generation or a separate paid-media authorization.

Task text and output are bounded to 32,000 UTF-8 bytes; system context has a
separate 64,000-byte bound. Each attempt has a 90-second deadline. A transient
failure gets at most two retries; two timeouts, exhausted retries, persistent
failure, or unsupported model disables delegation for the remainder of the run.
Completed task results are retained and never retried by the coordinator.

## Results, fallback, and cancellation

Receipts preserve input order and task IDs, with terminal `completed`, `refused`,
or `fallback_required` states, attempt counts, final text, and stable error reasons.
Partial/failed batches set the tool-result error flag without discarding successful
drafts. Missing stop events, truncated output, empty output, and oversized output
never become completed results.

Operational fallback removes the spawning tool from subsequent requests and tells
the parent to finish only unfinished work normally. Authentication, credits,
permissions, model refusals, and forbidden tool calls instead block denied work;
they do not authorize fallback around those restrictions.

The parent revalidates editor binding, session, model settings, timeline/manifest
revision, and plan revision before accepting drafts. Stale drafts are discarded.
The parent applies valid findings through ordinary shared domain tools and
`EditorUndo`; child text grants no authority over production gates. No undo group
spans a network await, and cancellation never undoes someone else's latest action.

Structured child/timeout tasks are canceled and drained when the parent stops.
`makeAgentStream` returns an owned `AgentStreamOperation` whose producer is
joined with `join()` on every exit (completion, failure, cancellation): workers
cancel their deadline race, finish text, and join before reporting terminal
results, so no producer outlives a drained run.
Session switching, tab closure, deletion, editor rebinding, and document close
cancel the owned run. Save-before-close awaits the run before its save snapshot.
Late tool receipts go only to their originating conversation, and old cleanup
cannot clear a newer run's streaming state.
Canceled exchanges also sync their terminal conversation for ordinary saves.
Hosted HTTP failures retain status and error code for denial classification.

`delegate_work` is app-runtime-only, not a remotely exposed MCP mutation tool.
Existing MCP tools remain the state-readback and shared-undo boundary.

## Measured parallelism

`AgentDelegationTests.parallelPreparationIsFasterThanSequentialExecution` runs four independent 150ms-latency tasks and requires delegation to finish at least 25% faster than the sequential sum with peak concurrency ≤2. Overlap is gate-proven, but wall-clock provider latency is not measured with a real model; treat the ratio as scheduling proof, not a speedup promise.

## Manual verification — pending

- In an isolated project, ask for two independent scene drafts from supplied
  evidence. Expect parallel preparation, then normal parent edits and one undo
  action per coherent edit. No duplicate commits or production approval inferred.
- Cancel during preparation, switch chats/tabs, and start another request. Expect
  no old result in the new chat and no incorrect clearing of streaming state.
- Change storyboard, timeline, source identity, or model while children run.
  Expect stale-result refusal and fresh preparation before edits.
- Use a model that rejects requests or simulate repeated transport timeouts.
  Expect finite retries and normal execution of unfinished permitted work, not
  repeated spawning or silent provider substitution.
- Close or Save As during work; reopen and inspect chat, project state, and undo.
  Rights, revealed faces, unresolved inspection, uniqueness, and storyboard approval
  must remain mandatory production blockers.
