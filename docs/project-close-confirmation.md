# Confirmed project closure

`AppState.closeProject` awaits `VideoProject.closeAfterSaving` before changing active-project state. The document registers its URL through its injected registry owner, never an implicit shared registry. Final native saves flush that owner.

`closeAfterSaving` performs the existing close preparation, then drains saves that arrived after preparation. It rechecks cancellation, the closing state, and coordinator idleness after every suspension; remaining unsaved changes repeat preparation. The final idle check, coordinator closure, and native document closure run synchronously on the main actor. Successful return confirms both closed coordinator state and removal from the document controller. Repeated closure is unchanged; cancellation before commit reopens admission. Native `close()` uses the same synchronous close operation, or an owned asynchronous close task when work or unsaved changes remain. Delegate approval callbacks retain their existing exactly-once handling.

## Authored proof

`ProjectCloseMCPTests` uses temporary packages, a loaded injected registry, in-memory MCP transports, and a deterministic save fence inserted after close preparation. It checks tool discovery, an actual MCP close request, independent disk readback, closed/document/binding state, isolated registry persistence, repeated closure, failed final-save refusal, and unchanged empty undo history. Separate direct tests cover cancellation while draining a late save and native `close()` waiting before document removal; they do not prove MCP protocol cancellation or delegate callback counts. No test creates project windows or accesses a production registry.

Frozen focused gate 7 passed 140 tests in 21 suites, including close persistence, actual in-memory MCP close/refusal, and independent document/disk/binding readback. Frozen `tsan-1` passed 137 tests in 19 suites without race diagnostics, including close and package coordination. Both preserved source hashes; pending finalization/narration overlays are excluded. The broader full suite failed 32 issues in 2,452 tests; no full integration or human UI pass is claimed. Final gates include:

```sh
swift test --filter 'ProjectCloseMCPTests|ProjectClosePersistenceTests|ProjectPackageCoordinatorTests'
swift build
```

The implementing subagent ran only `git diff --check`; main's evidence above supersedes that test limitation, not the pending native checks. Native UI verification remains manual: close with Command-W and the window button while a save is pending; expect the document to remain open until draining finishes. Force a final-save failure; expect an error and the same active project, then verify editing resumes. Exercise concurrent close requests, cancellation, and closing an inactive project without changing focus to it. Approval-callback counts and active-project navigation also need integration verification.

## Quit quiescence remains blocked

This change does not solve post-save edits during application termination. `ProjectPackageCoordinator` gates package work, not every editor mutation. Native event/menu/undo guards alone do not cover already-started UI work that commits after an `await`; external MCP requests are not drained by `AgentService.cancelAndWait`.

- `Sources/CompositorPro/MediaPanel/CaptionsTab/CaptionTab.swift:581` starts an unowned UI task and calls `generateCaptions` at line 607.
- `Sources/CompositorPro/Editor/ViewModel/EditorViewModel+Captions.swift:213–253` awaits transcription/spec preparation, then places the caption track without lifecycle admission. An unchanged timeline snapshot does not prove the document remains editable.
- `Sources/CompositorPro/Agent/Tools/ToolExecutor.swift:211` awaits tool execution without a common whole-intent admission lifetime. `AgentService.cancelAndWait` only drains its own `runTasks` at `Sources/CompositorPro/Agent/Chat/AgentService.swift:512–517`.
- `Sources/CompositorPro/App/AppDelegate.swift:61–75` saves projects sequentially, then awaits skill and MLX teardown before replying. No complete edit fence protects the already-saved projects through that interval.

A complete fix needs one editor-intent admission lifetime shared by native input, UI tasks, and Agent mutation tools, plus a cancellation policy for active gestures, text editing, sheets, and deferred callbacks. Nested tool/package admission must remain safe when a save fence arrives: a tool lease cannot block the save it awaits. Refuse new intents explicitly, cancel or drain previously admitted intents, permit existing package leases to finalize, then save only after both intent and package work drain. Do not claim that SwiftUI disabling or a keyboard/menu-only gate establishes quiescence.

No deterministic gate-B/edit-A refusal test was authored because the required admission invariant is not implemented. Verification after that boundary exists: open temporary projects A and B, gate B's drain after A's final save, attempt edits in A through native mouse/keyboard/menu/undo and MCP, and verify explicit refusal, unchanged undo history, and unchanged independent disk state. Cancel quit and verify every route reopens. Also exercise an in-flight caption operation across the fence, active text editing, mouse-up after gesture cancellation, and a late save during native close.

## Whole-intent implementation contract

Extend `ProjectPackageCoordinator` with separate intent leases rather than a second lifecycle owner. Intent admission must reserve synchronously before scheduling UI work, pin its editor/document, retain terminal publication and cleanup, and reject foreign or expired inherited contexts. Nested same-project domain work shares valid admission; merely inheriting task-local context does not extend its lifetime.

Ordinary save prerequisites remain package mutations only: waiting on whole intents would deadlock tools that await saves. Whole-project close drains intents, package mutations, owned tasks, and queued/active saves. Valid admitted intents may acquire child package work while closing; independent queued/new work refuses. Preserve FIFO save fences and existing granted package leases. Scoped closing tokens prevent overlapping native close and quit attempts from reopening each other's fences.

`ToolExecutor.executeWithOrigin` needs admission before its first suspension, retained through receipt preparation. Fence every project-scoped tool unless proven side-effect-free; inactive-read permission is not purity. Project open/create/close use lifecycle admission separately so close never waits for its own edit lease. External MCP handlers are covered by the intent owner, not conversation-task cancellation.

Shared caption, storyboard, narration, sync/multicam, audio analysis, media import-to-placement, speaker identification, and deferred UI workflows need the same domain boundary. Native gesture rollback, accepted text edits, pending settings continuations, sheet completion, undo/redo, and late mouse-up require explicit resolution at the synchronous fence. `EditorUndo.register` is not a mutation gate because assignments may already have happened; refusal must precede domain mutation and undo grouping.

Deterministic tests must prove an admitted edit drains before final save, a new edit refuses in every already-saved project, nested save/package work avoids self-deadlock, expired context refuses, and overlapping close cancellation releases only its own token. Include real MCP discovery, independent state/package readback, unchanged refused-operation undo, cancellation, and failed-save reopening.

Intent fencing does not establish transport shutdown: `MCPService.stop`, HTTP handlers, and export jobs still need terminal producer/output ownership. Uncooperative framework work must block or refuse graceful quit rather than produce a false drained state. Lost acknowledgment of a paid submission still requires backend idempotency or reconciliation.

### Isolated primitive handoff

The coordinator-only intent foundation is implemented in an isolated worker, not integrated into the application. It adds manual/scoped intent leases, synchronous owned-task reservation, membership-validated task-local nesting, intent-aware child package admission while closing, and an admission epoch preventing unscheduled independent mutation requests from crossing close/reopen. Ordinary save prerequisites remain mutations only; idle/close includes intents and owned cleanup.

Worker and main independently ran the dependency-free Swift Testing and Thread Sanitizer harness: 27 tests in two suites passed, covering 41 parameterized executions, with no race diagnostics. This includes 20 new intent tests and seven existing coordinator-only tests. Exact coordinator/test files were symlinked into the harness; `ProjectPackageIO` was a stub. Main verified handoff hashes and unchanged live coordinator baseline, not application integration. Real package I/O, ToolExecutor/domain/native admission, overlapping close ownership, MCP/undo/quit, full build, and human UI remain unverified. Boolean close/cancel behavior still permits one attempt to reopen another's fence.

### Transport quiescence investigation

Read-only tracing found additional unfinished ownership boundaries. `AgentClientTypes.makeAgentStream` returns events but hides its producer task; stream termination cancels without joining it. `AgentService.cancelAndWait` and stream presentation join consumers only. Delegation has the same hidden-producer gap; its existing test awaits eventual producer completion separately from the run. An owned stream operation must expose producer completion, and ordinary/failed/canceled/rejected collection must join it before reporting drained state.

`MCPService` starts and stops HTTP through unretained tasks; stop drops owners and reports stopped before asynchronous cleanup. `MCPHTTPServer` has no owned accepted-connection/request/output registry, does not await final send callbacks, and can publish session/fallback initialization after stop. Shutdown must fence admission synchronously, retain/coalesce startup and shutdown, revalidate initialization, and drain admitted POST/results before terminating long-lived GET streams and connections.

The installed MCP SDK's `Server.stop` and `waitUntilCompleted` do not join complete request dispatch or response output. An app handler count alone misses requests accepted before the SDK handler starts. Closing that gap requires app-owned dispatch lifetime or narrowly pinned SDK drain support; disconnecting first converts late sends into connection-closed errors instead of proving completion. This investigation implemented no transport fix.

Deterministic proof must gate producer cleanup, admitted handler completion, and final send completion independently. Include early rejection, ordinary completion, startup/session/fallback races, request accepted before handler entry, stateful/stateless POST, idle GET, partial input, peer disconnect, send failure, and concurrent stop. Stop must remain pending until each admitted terminal result and owned cleanup completes; fresh requests must refuse without mutation.
