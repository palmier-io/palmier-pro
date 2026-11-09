# Explainer production done

Completed items moved from [todo.md](todo.md). Each line records what was finished and where its verification evidence lives in the task sections of todo.md.

## User requirements

- Give every timeline placement its own clip ID; expose stable input identity independently so the Agent can recognize duplicate source use. Identity/move regressions and MCP readback are documented in task 5b; complete output enforcement remains unchecked above.
- Record what/how, acceptance conditions, evidence, and limitations in this file. Maintain these records as implementation continues; do not check off unverified capabilities.
- Add subagent spawning support for faster editing. Default to parallel subagents for independent work; fall back to normal execution on repeated timeouts, unsupported models, or persistent failures. Preserve shared state, undo, cancellation, and production gates (task 13a; implementation verified, provider/UI and performance proof pending).

## Tasks

### 1. Fix tool discovery and execution contracts

**What:** Remove misleading instructions that cause premature stopping, duplicate assembly, or missed capabilities.

**How:**
- Correct `apply_plan`: `commit:false` checks readiness; successful `commit:true` assembles clips and marks the plan applied. Preserve existing shared assembly rather than introduce another operation.
- Advertise local Lottie JSON import in the import contract.
- Reconcile shot-candidate metadata promises with actual receipts. Obtain dimensions and visual evidence through existing inspection paths; do not add synchronous metadata loading to search receipts.
- Honor requested duration and format. Separate reference style from runtime; group genuinely missing decisions instead of silently choosing 30–60 seconds.
- Change long-job continuation instructions only when an owned wait/resume mechanism exists in task 8.

**Start here:** [ToolDefinitions.swift](Sources/CompositorPro/Agent/Tools/ToolDefinitions.swift), [ToolExecutor+Plan.swift](Sources/CompositorPro/Agent/Tools/ToolExecutor+Plan.swift), [ToolExecutor+Import.swift](Sources/CompositorPro/Agent/Tools/ToolExecutor+Import.swift), [ShotCandidates.swift](Sources/CompositorPro/Agent/Retrieval/ShotCandidates.swift), [AgentInstructions.swift](Sources/CompositorPro/Agent/Tools/AgentInstructions.swift).

**Done when:** MCP discovery matches execution. An isolated plan assembles once, state readback confirms clips/status, undo restores prior state, and invalid or unchanged requests create no edits or empty undo steps.

**Verified:** `swift build` and `swift test --filter 'ExplainerContractsMCPTests|ShotCandidateBundleTests|PlanEditToolTests|FindShotCandidatesToolTests|ToolExecutorImportMediaTests'` passed (26 tests). New discovery/metadata tests failed before the fix. In-memory MCP verifies readiness-only behavior, one assembly, repeated-call no-op, plan/timeline readback, undo, and invalid-request refusal. Requested duration/format is Agent guidance, not a new automatic duration planner. No UI or live stock-quality verification claimed.

### 2. Turn references into an editorial recipe

**What:** Capture how a film explains its subject, not merely its palette or effects.

**How:**
- Record narrative arc, recurring scene families, typography roles, geographic scale changes, evidence treatment, pacing intent, and available audio observations.
- Attach reference timestamps and inspection coverage. Mark observed, inferred, and unverified properties separately; do not claim motion/audio analysis from thumbnails or captions.
- Separate transferable editorial principles from exact narration, logos, protected assets, voice identity, and sponsorship.
- Accept an externally prepared recipe first. Reuse existing inspection capabilities for supported media; add acquisition only where a concrete input gap remains.
- Keep requested output duration independent of reference duration.

**Done when:** A supplied recipe produces a chapter/scene outline with traceable rationale and truthful limitations, without requiring the user to explain every visual treatment.

**Verified:** `swift test` passed (2,140 tests in 324 suites). Recipe MCP coverage verifies a 90-second authored outline independent of its 21-minute reference, chapter/shot cue citations, limitations, package readback, atomic refusal, no-op, and undo. The Agent authors the outline from supplied analysis; the app does not acquire or automatically analyze reference URLs. See [reference recipe handoff](docs/explainer-reference-recipes.md). UI/storyboard review remains task 5a.

### 13a. Spawn subagents for independent editing work

**User requirement:** Default to parallel subagents for independent work; fall back to normal execution on repeated timeouts, unsupported models, or persistent failures. Preserve shared state, undo, cancellation, and production gates.

**How:** Trace existing model/tool execution and job ownership before changing it. Children receive immutable task context and explicit independent scopes. Shared editor mutations still use existing domain operations and shared `EditorUndo`; no child can bypass storyboard approval, uniqueness, package coordination, or stale-result validation. Bound concurrency and retries, own child handles, propagate cancellation, and report failed/canceled/fallback results without duplicate commits or success-shaped failures. Do not expose credentials to children or create a second editor state owner.

**Done when:** Independent preparation runs concurrently by default, unsupported models and repeated timeout/failure switch to normal execution, cancellation tears down owned work, and isolated runtime/MCP tests independently verify shared state, undo, stale-result refusal, and production gates.

**Implemented:** App-only `delegate_work` runs immutable text-preparation tasks through the parent's selected client, with two concurrent children, eight tasks per batch, 32,000-byte task/output caps, a 64,000-byte system cap, 90-second deadlines, and at most two transient retries. Stable ordered receipts retain completed drafts. Unsupported models, repeated timeouts, or exhausted/persistent failures disable spawning for that run; authentication, credits, permission, model refusal, and forbidden child tools instead block denied work. Hosted HTTP errors preserve status/code so a denial cannot be mislabeled as operational fallback. Children have no tools/editor access, never approve or attest, and cannot nest. The parent revalidates context and alone applies shared domain edits/undo. Canceled run handles remain owned and drain before later runs; close drains reject admission. Late results and canceled exchanges persist only in their originating chat. [Contract and manual plan](docs/agent-delegation.md).

**Final-source verification:** Isolated staged-only `swift build` passed. `swift test --filter 'AgentDelegation|AgentStreamPresentationTests|StoryboardMCPTests|UndoToolTests'` passed 54 tests in 5 suites. `swift test --sanitize thread --filter 'AgentDelegation|AgentStreamPresentationTests|UndoToolTests'` passed 44 tests in 4 suites, with no reported races. Full staged-only `swift test` ran 2,243 tests in 336 suites and failed only unchanged `CustomAgentModelPersistenceTests.aRemoteCustomModelWithAStoredKeyIsSelectable`; no final-source staged-only full pass is claimed. Earlier same-snapshot attempts also hit that routing test, while its isolated suite passed 9 tests. Earlier working-tree full tests passed 2,262 tests before final persistence/hosted-error fixes; that is not final-source proof. Runtime tests independently read edits and undo through in-memory MCP, and verify discovery stays app-only, source/stale/session/cancel/close behavior, denial/fallback instructions, and refusal to bypass storyboard approval. Real provider/UI, Save As/close/quit, transport cleanup, and performance checks remain pending under task 13; no speedup or installed-app claim. Client streams signal producer cancellation but expose no producer join handle.
