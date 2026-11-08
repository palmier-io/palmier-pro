# Confirmed project closure

`AppState.closeProject` awaits `VideoProject.closeAfterSaving` before changing active-project state. The document registers its URL through its injected registry owner, never an implicit shared registry. Final native saves flush that owner.

`closeAfterSaving` performs the existing close preparation, then drains saves that arrived after preparation. It rechecks cancellation, its scoped close owner, and coordinator idleness after every suspension; remaining unsaved changes repeat preparation. The final idle check, coordinator closure, and native document closure run synchronously on the main actor. Successful return confirms both closed coordinator state and removal from the document controller. Repeated closure is unchanged; cancellation releases only that request's owner, and admission reopens only when the last owner releases. Native `close()` uses the same synchronous close operation, or an owned asynchronous close task when work or unsaved changes remain. Delegate approval callbacks retain their existing exactly-once handling.

## Authored proof

`ProjectCloseMCPTests` uses temporary packages, a loaded injected registry, in-memory MCP transports, and a deterministic save fence inserted after close preparation. It checks tool discovery, an actual MCP close request, independent disk readback, closed/document/binding state, isolated registry persistence, repeated closure, failed final-save refusal, and unchanged empty undo history. Separate direct tests cover cancellation while draining a late save and native `close()` waiting before document removal; they do not prove MCP protocol cancellation or delegate callback counts. No test creates project windows or accesses a production registry.

Frozen focused gate 7 passed 140 tests in 21 suites, including close persistence, actual in-memory MCP close/refusal, and independent document/disk/binding readback. Frozen `tsan-1` passed 137 tests in 19 suites without race diagnostics, including close and package coordination. Both preserved source hashes; pending finalization/narration overlays are excluded. The broader full suite failed 32 issues in 2,452 tests; no full integration or human UI pass is claimed. Final gates include:

```sh
swift test --filter 'ProjectCloseMCPTests|ProjectClosePersistenceTests|ProjectPackageCoordinatorTests'
swift build
```

The implementing subagent ran only `git diff --check`; main's evidence above supersedes that test limitation, not the pending native checks. Native UI verification remains manual: close with Command-W and the window button while a save is pending; expect the document to remain open until draining finishes. Force a final-save failure; expect an error and the same active project, then verify editing resumes. Exercise concurrent close requests, cancellation, and closing an inactive project without changing focus to it. Approval-callback counts and active-project navigation also need integration verification.

## Quit quiescence remains blocked

Scoped close ownership does not solve every post-save edit during application termination. `ProjectPackageCoordinator` gates admitted tool intents and package work, not every native editor mutation. Native event/menu/undo guards alone do not cover already-started UI work that commits after an `await`; external MCP output is not drained by `AgentService.cancelAndWait`.

- `Sources/CompositorPro/MediaPanel/CaptionsTab/CaptionTab.swift:581` starts an unowned UI task and calls `generateCaptions` at line 607.
- `Sources/CompositorPro/Editor/ViewModel/EditorViewModel+Captions.swift:213–253` awaits transcription/spec preparation, then places the caption track without lifecycle admission. An unchanged timeline snapshot does not prove the document remains editable.
- `Sources/CompositorPro/Agent/Tools/ToolExecutor.swift` now retains whole-intent admission through tool execution and receipt preparation. SDK dispatch before handler entry and HTTP terminal output still require their own transport drain.
- `Sources/CompositorPro/App/AppDelegate.swift` now reserves every project close owner before its first suspension and validates them through teardown. Unadmitted native edits, exports, deferred callbacks, and remaining caches can still cross the final-save interval.

A complete fix needs one editor-intent admission lifetime shared by native input, UI tasks, and Agent mutation tools, plus a cancellation policy for active gestures, text editing, sheets, and deferred callbacks. Nested tool/package admission must remain safe when a save fence arrives: a tool lease cannot block the save it awaits. Refuse new intents explicitly, cancel or drain previously admitted intents, permit existing package leases to finalize, then save only after both intent and package work drain. Do not claim that SwiftUI disabling or a keyboard/menu-only gate establishes quiescence.

The complete gate-B/edit-A native refusal test remains unauthored because domain/UI admission is unfinished. Required verification: open temporary projects A and B, gate B's drain after A's final save, attempt edits in A through native mouse/keyboard/menu/undo and MCP, and verify explicit refusal, unchanged undo history, and unchanged independent disk state. Cancel quit and verify every route reopens. Also exercise an in-flight caption operation across the fence, active text editing, mouse-up after gesture cancellation, and a late save during native close.

## Whole-intent implementation contract

Extend `ProjectPackageCoordinator` with separate intent leases rather than a second lifecycle owner. Intent admission must reserve synchronously before scheduling UI work, pin its editor/document, retain terminal publication and cleanup, and reject foreign or expired inherited contexts. Nested same-project domain work shares valid admission; merely inheriting task-local context does not extend its lifetime.

Ordinary save prerequisites remain package mutations only: waiting on whole intents would deadlock tools that await saves. Whole-project close drains intents, package mutations, owned tasks, and queued/active saves. Valid admitted intents may acquire child package work while closing; independent queued/new work refuses. Preserve FIFO save fences and existing granted package leases. Scoped closing tokens prevent overlapping native close and quit attempts from reopening each other's fences.

`ToolExecutor.executeWithOrigin` reserves admission before its first suspension and retains it through receipt preparation. Every project-scoped tool is fenced; inactive-read permission is not purity. Project open/create/close use lifecycle admission separately so close never waits for its own edit lease. External MCP tool execution is covered by the intent owner, not conversation-task cancellation; transport dispatch and final output remain outside that proof.

Shared caption, storyboard, narration, sync/multicam, audio analysis, media import-to-placement, speaker identification, and deferred UI workflows need the same domain boundary. Native gesture rollback, accepted text edits, pending settings continuations, sheet completion, undo/redo, and late mouse-up require explicit resolution at the synchronous fence. `EditorUndo.register` is not a mutation gate because assignments may already have happened; refusal must precede domain mutation and undo grouping.

Deterministic tests must prove an admitted edit drains before final save, a new edit refuses in every already-saved project, nested save/package work avoids self-deadlock, expired context refuses, and overlapping close cancellation releases only its own token. Include real MCP discovery, independent state/package readback, unchanged refused-operation undo, cancellation, and failed-save reopening.

Intent fencing does not establish transport shutdown: `MCPService.stop`, HTTP handlers, and export jobs still need terminal producer/output ownership. Uncooperative framework work must block or refuse graceful quit rather than produce a false drained state. Lost acknowledgment of a paid submission still requires backend idempotency or reconciliation.

### Isolated primitive handoff

The initial coordinator-only handoff added manual/scoped intent leases, synchronous owned-task reservation, membership-validated task-local nesting, intent-aware child package admission while closing, and an admission epoch preventing unscheduled independent mutation requests from crossing close/reopen. Ordinary save prerequisites remain mutations only; idle/close includes intents and owned cleanup. The later integrated slice and application gates supersede its original harness-only verification scope.

Worker and main independently ran the initial dependency-free Swift Testing and Thread Sanitizer harness: 27 tests in two suites passed, covering 41 parameterized executions, with no race diagnostics. This included 20 new intent tests and seven existing coordinator-only tests. Exact coordinator/test files were symlinked into the harness; `ProjectPackageIO` was a stub. Those results alone did not prove application integration. The subsequent scoped-owner slice replaces the unsafe shared Boolean; broader evidence follows below. Domain/native UI and complete quit remain unfinished.

### Transport quiescence investigation

Read-only tracing found additional unfinished ownership boundaries. `AgentClientTypes.makeAgentStream` returns events but hides its producer task; stream termination cancels without joining it. `AgentService.cancelAndWait` and stream presentation join consumers only. Delegation has the same hidden-producer gap; its existing test awaits eventual producer completion separately from the run. An owned stream operation must expose producer completion, and ordinary/failed/canceled/rejected collection must join it before reporting drained state.

`MCPService` starts and stops HTTP through unretained tasks; stop drops owners and reports stopped before asynchronous cleanup. `MCPHTTPServer` has no owned accepted-connection/request/output registry, does not await final send callbacks, and can publish session/fallback initialization after stop. Shutdown must fence admission synchronously, retain/coalesce startup and shutdown, revalidate initialization, and drain admitted POST/results before terminating long-lived GET streams and connections.

The installed MCP SDK's `Server.stop` and `waitUntilCompleted` do not join complete request dispatch or response output. An app handler count alone misses requests accepted before the SDK handler starts. Closing that gap requires app-owned dispatch lifetime or narrowly pinned SDK drain support; disconnecting first converts late sends into connection-closed errors instead of proving completion. This investigation implemented no transport fix.

Deterministic proof must gate producer cleanup, admitted handler completion, and final send completion independently. Include early rejection, ordinary completion, startup/session/fallback races, request accepted before handler entry, stateful/stateless POST, idle GET, partial input, peer disconnect, send failure, and concurrent stop. Stop must remain pending until each admitted terminal result and owned cleanup completes; fresh requests must refuse without mutation.

### Isolated Agent transport handoff

`AgentStreamOperation` exposes events, cancellation, and actual producer completion. Presentation and delegation cancel and join producers on every exit, including consumer rejection, cancellation, stream failure, and event completion before producer cleanup. Observed stream errors/refusals remain authoritative; otherwise late producer failure reaches the terminal result. Producers use their existing provider request paths, not a second transport.

Worker/main dependency-free harnesses passed 30 tests in three suites under complete strict concurrency, warnings-as-errors, and Thread Sanitizer. A no-join mutation failed its regression. Frozen real-app `transport-focused` passed 50 tests in six suites, including client migrations and the real `AgentService` case omitted by the harness. `transport-build` passed `swift build`; `transport-full` ran 2,490 tests in 364 suites with only the unchanged custom-model select-after-wait routing issue. No selective full-suite pass is claimed.

The first real-app sanitizer gate reported no races but failed an existing burst test's wall-clock-dependent snapshot bound. The corrected test delivers its burst within one nonsuspending actor turn, while separate end-to-end coverage preserves all text deltas; production timers are unchanged. Frozen `transport-focused-2` and `transport-tsan-2` each passed 51 tests in six suites with unchanged hashes and no race diagnostics. Exact ten-path integration matches that snapshot; 925 other tracked source/test/package files match the pre-transport HEAD. Live `swift build` and the same focused filter passed (51 tests in six suites) with unchanged source hashes; that workspace includes unrelated finishing/speech/credential changes and is not selective full-suite proof. Transport is committed as recorded below. MCP/HTTP dispatch/output, complete quit, provider quality, native UI, and installation remain unfinished.

### Scoped close-owner integration

The isolated coordinator/native handoff replaces the shared Boolean with independent `CloseLease` owners. Only canceling the final live owner reopens admission; foreign, expired, duplicate, and post-close cancellation cannot release another attempt. A valid idle owner can confirm closure once, expiring all owners. Native delegate requests share one native owner, direct close has an owned task, and quit reserves every project owner synchronously before its first suspension. `saveBeforeClosing(using:)` borrows that owner, and lifecycle operations refuse execution inside their own edit intent.

The worker passed 30 exact-source coordinator/intent tests normally and under Thread Sanitizer, parsed all twelve changed Swift files, and reproduced the Boolean-fence regression. Main's real-app snapshot corrected Swift's region-checker rejection of canceled-open cleanup through an explicit actor-isolated async operation, preserving cancellation-independent draining without unchecked sendability. New MCP tests use the installed SDK's three-value text payload.

Frozen `close-intent-before-3` reproduced missing ToolExecutor admission: two tests failed ten issues, including false close idleness, late plan mutation, undo registration, and invalidated measurement. `close-intent-after` passed both tests with unchanged hashes. The candidate fences all project tools through execution, feedback, analytics, and ID shortening; lifecycle commands stay outside their own edit scope. Ordinary saves remain nonblocking on intents. Independent readback and undo verify measured state after reopening admission.

`close-deferred-before` ran 61 tests in seven suites with six issues: existing MCP tests expected reads while fenced and generation-specific unavailable errors. All project tools now share stable `project_unavailable`/`operation_canceled` refusal values; tests must explicitly reopen admission before readback. A separate deterministic `close-owned-mutation-before` reproduced lost owned mutation lifetime after its initiating intent ended: immediate and save-queued cases failed four issues. The candidate reserves an independent child intent synchronously inside `startMutation`, retains it through queued admission, cleanup and terminal publication, and preserves rejection of expired/foreign callers and independent requests crossing close/reopen. Seven parameterized cancellation/closing/cleanup cases are included in the passing gate below.

`close-owned-mutation-after` passed 75 tests in nine suites with unchanged hashes; `close-build` passed. Broader `close-focused` ran 270 tests in 36 suites and failed one thumbnail retry assertion in `VideoProjectBackgroundWorkTests`; its cause and focused correction follow below. Scoped-close/intent source is integrated as the exact verified 15-path merge, preserving unrelated live ToolExecutor changes. Native UI, domain/UI admission, export/cache ownership, MCP/HTTP output draining, and complete quit proof remain unfinished.

Transport producer integration is committed as `af1a783`; all twelve committed files match frozen candidates, and unrelated live work remained unchanged. Scoped-close source is not included in that commit.

The thumbnail failure comes from retrying inside a canceled stale-render task: synchronous admission correctly rejects that canceled caller. The candidate registers one independent retry intent from the newer request, joins the canceled renderer, then requests current state. Further changes coalesce; close cancels/drains both renderer and retry. `close-thumbnail-after` passed 50 tests in four suites with unchanged hashes.

Combined `close-transport-build-1` and `close-transport-bundled-1` passed. `close-transport-focused-1` and `close-transport-tsan-1` each passed 323 tests in 43 suites; inspected sanitizer logs contain no race diagnostics. `close-transport-full-1` ran 2,532 tests in 368 suites and failed one assertion in `aRemoteCustomModelWithAStoredKeyIsSelectable`: the unchanged test selects the custom model after its wait loop. That run reported no Piper crash; earlier crashes remain unresolved. All 941 frozen source/test/package hashes stayed unchanged. This is incremental evidence, not a clean build or full-suite pass.

### Real SDK dispatch probes

Six deterministic probes against SDK 0.12.0 (`6132fd4b5b4217ce4717c4775e4607f5c3120129`) passed normally and under TSan, confirming the missing boundary rather than fixing it. They use real SDK server/parser/stateful/stateless transports with gated transport and tool fixtures, not TCP or an editor. Stop/wait can return before pre-handler dispatch, suspended handlers, or pending sends. Canceled handlers have no transport terminal receipt; DELETE/disconnect can exhaust POST streams while handlers remain active. The installed checkout's broken alternate object path prevented canonical cleanliness verification, so exact upstream provenance must be established before a fork is accepted.

A bounded isolated follow-up owns pinned SDK dispatch reservations, inbound sealing, explicit no-response completion, and awaited dispatch/send drain. No production SDK dependency, MCPService/HTTP lifecycle, final connection callback, or quit implementation has changed from that investigation.

Dependency-path audit found the first combined gate's Sparkle metadata referenced an earlier temporary artifact directory. Its local cloned artifact is byte-identical. After all first gates ended, that single metadata path was rebased to the local clone; every artifact path now resolves inside the snapshot. Unique `close-transport-{build,focused,bundled,tsan}-2` gates verify the repaired scratch. Historical build-graph warnings remain a limitation; metadata repair does not prove a clean build or absence of earlier external writes.

All four repaired-scratch gates passed with `--disable-automatic-resolution --jobs 2`: normal/BundledSpeech builds and 323 tests in 43 suites normally and under TSan. Inspected second logs contain no sanitizer race diagnostics or stale-path warnings. All 941 frozen hashes remain unchanged, and every artifact path is local. Existing source/dependency warnings and Convex's macOS 26.2 minimum warning remain. This is still incremental evidence; the full suite was not rerun after metadata repair.

Live `swift build --disable-automatic-resolution --jobs 2` and the same focused `swift test` filter passed: 323 tests in 43 suites, with all source/test/package hashes unchanged. The live workspace includes unrelated finishing, speech, and credential work, so this is not selective full-suite evidence. All 15 merged paths match their approved hashes; 933 other source/test/package files were preserved. Selective commit must use frozen ToolExecutor bytes, leaving its unrelated live routes unstaged.

## Manual close verification

Use disposable saved projects, never production media. These scenarios remain unverified until the user confirms them:

- Start an import or narration measurement; close with Command-W and the window button. Expect admitted work and its cleanup to finish before final save and document removal; new project tools must refuse while closing.
- Close two projects during quit; issue another native close, then cancel only one request. Expect the other owner's fence to remain active. Cancel the last owner; editing must resume without stale close tasks.
- Force final-save failure using a disposable unwritable destination. Expect an error, an open document, unchanged active-project binding, and reopened editing after all close owners release.
- Change timeline thumbnails repeatedly, then close while the previous render is canceled. Expect no late thumbnail publication and no close hang; canceled close must permit a fresh thumbnail request.
- Verify focus stays unchanged when closing an inactive project. Exercise Return, Escape, mouse-up after cancellation, undo/redo, empty timelines, and disabled controls.
- After successful close, reopen and inspect package media, plan timing, and the last admitted edit. Compare with the pre-close state; refused requests must add no undo step.

Native gesture/text/sheet admission, exports, visual caches beyond project thumbnails, HTTP terminal output, and complete quit quiescence remain separate unfinished boundaries.
