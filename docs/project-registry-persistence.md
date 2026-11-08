# Project registry persistence

## Ownership and execution

`ProjectRegistry` owns authoritative entries on the main actor. Both the shared
registry and `init(fileURL:)` start an owned asynchronous load task. Initializing
a registry never reads its JSON file or creates its parent directory on main.
Injected file URLs never create or inspect the production storage directory.

One serial utility queue owns registry reads, JSON decoding and encoding, atomic
snapshot writes, parent-directory creation, and project trash operations. The
queue receives immutable entry snapshots; it never accesses observable state.
Use one registry owner per backing file.

The registry retains its load and persistence tasks until they finish. Mutation
methods update entries synchronously after loading, then schedule one persistence
task. That task writes the current snapshot, records it as persisted, and repeats
only if entries changed during the write. Snapshots cannot overtake each other.
Transient changes may coalesce before a snapshot is written.

`persistedEntries` is an observation-ignored cache of the last successfully loaded
or written snapshot. It changes only after a successful disk operation. Equality
against this cache decides whether another write is required.

## Loading and no-ops

Before load completes, mutations queue in main-actor call order. Successful load
replays them against the decoded entries, preserving existing IDs and creation
dates. Register/open and rename dates are captured when requested, not when load
finishes. Use `waitUntilLoaded()` before reads that require restored entries.

An absent registry file means an empty registry. Merely loading or flushing it
does not create a file or directory. A corrupt or unreadable existing file is a
load failure, not an empty-registry fallback. Queued mutations are refused, future
mutations remain refused, and the original file is never overwritten. Reopen a
registry after repairing the file to admit mutations again.

Removing an unknown URL, renaming an unknown source, or updating a URL to its
same standardized URL changes neither state nor persisted bytes or modification
date. A queued batch with no net change also performs no write. Registering a
known project remains meaningful: it updates its last-opened date.

## Flush and failures

`flush() async throws` waits for loading and all currently admitted entry changes
to reach disk, including newer entry changes received while a write is suspended.
It returns only when the latest entries equal the successful persisted snapshot
and no persistence task remains. Calls made after it returns are new work.

Automatic writes stop on failure. `persistenceError` exposes the terminal failure
on the main actor, and `Log.project` records phase plus stable error domain/code
off-main. `flush()` throws `ProjectRegistryPersistenceError`, with stable codes
`registry_load_failed` or `registry_write_failed` and underlying domain/code.
Write failure leaves entries in memory; a later flush or meaningful mutation
retries the latest snapshot. Successful persistence clears the write error.

Cancelling a flush caller throws `CancellationError` without cancelling shared
load or persistence work. Cancellation while awaiting a disk operation is observed
when that operation completes. Admitted writes remain owned and drainable; there
is no partially cancelled registry commit.

Deletion awaits successful registry loading before touching project files; load
failure or caller cancellation reports refused entries through `failedNames`.
Callers must await their asynchronous delete operation before flushing its entry
removal. Flush drains admitted registry changes, not a caller's unfinished action.

## Native document and application coordination

Native document construction accepts an explicit `ProjectRegistry` for tests;
production defaults to `.shared`. Its URL-rebase setter forwards only the entry
mutation. It must not encode, write, or synchronously wait for registry persistence.

After successful native save completion, await the document's `registry.flush()`
before releasing its save fence and reporting save success. Propagate registry
failure through that completion instead of silently reporting success. Application
restart and termination must await `ProjectRegistry.shared.flush()` after admitting
the final document operations and before confirming termination. Do not block
main while waiting; refuse or surface failure instead of exiting early.

`VideoProject.load(from:)` also needs an injected-registry argument for tests;
otherwise its default document initializer starts a real shared-registry load.
All test-created documents must use a temporary registry, including tests that do
not expect to rename a project. Await flush before deleting temporary fixtures.

## Accessibility

`ProjectEntry.isAccessible` is removed. Immutable `ProjectAccessibility` results
identify the exact entry ID and URL. Its `@concurrent` batch reader runs off-main,
uses the existing asynchronous semaphore to admit one batch at a time, and reads
each distinct URL once per batch. It checks cancellation between locations and
after releasing the permit. No availability cache survives the batch.

Fresh URL resource values distinguish readable locations from missing paths and
unavailable locations, including permission or other filesystem failures. A fresh
URL avoids reusing Foundation's cached resource metadata after a file is removed
or restored. Non-file URLs are unavailable without a filesystem probe.

`Sources/CompositorPro/Home/ProjectCard.swift` owns only its current result and
request in view state. Body and context-menu reads are pure state reads. One
SwiftUI lifecycle task validates each request, keyed by entry ID, exact URL, and
unique request identity. It refreshes on appearance, URL/ID or last-opened changes, and app
activation; disappearance or deactivation clears the request. Selection changes
invalidate a pending open/reveal action. Cancelled or superseded completions
cannot update state or perform that action. An action also requires the initiating
key window to remain current when its check finishes.

Open and Reveal in Finder request a fresh check before invoking their callbacks.
Unknown availability is not labelled missing. Missing results retain the existing
"File missing" label; other failures use the existing localized read-failure copy.
No synchronous background-queue wait, persistent cache, or new UI strings are used.

`Sources/CompositorPro/Agent/Tools/ToolExecutor+Projects.swift` awaits registry
loading, snapshots entries and document identities/URLs, and checks one immutable
batch. Before returning JSON, it revalidates the entire registry snapshot, open
documents, session project, visible project, and returned result keys. Changed
context returns an explicit retry error instead of stale receipts. `isAccessible`
is true only for a readable location; missing, offline, unsupported, or unreadable
locations return false. The redundant synchronous open preflight is also removed;
the existing off-main document load owns actual open failures.

Both `ToolExecutor` constructors accept optional registry and accessibility-check
dependencies, defaulting to nil. Constructing a standalone executor does not
initialize the shared registry. `manage_project` listing resolves the injected
registry or the shared registry only when invoked. ID and name selectors await
loading of that same registry before resolving entries; path selectors bypass
registry loading entirely. AppState's open and create operations are unchanged.
The direct `listProjects` test seam requires an explicit registry.

Registry location matching compares standardized filesystem paths, not complete
URL representations. An NSURL-backed existing directory may standardize with a
trailing slash while a decoded URL preserves its original slashless directory
hint. Lookup, registration, removal, and rebasing treat those as the same project
location. Rebasing between hints alone is a no-op; real path changes retain the
entry ID. Decoded URLs are not rewritten during load. Accessibility keys still
require the exact entry ID and URL; their equality is intentionally unchanged.

`Tests/CompositorProTests/Project/ProjectAccessibilityTests.swift` covers off-main
reads from a main-actor request, exact keys, per-batch URL deduplication, missing
versus unavailable failures, fresh removal/restoration, cancellation, permit
release, project-list context identity changes, ID/name resolution before the
injected registry finishes loading, and nil-registry path resolution. Existing
registry tests use the batch helper rather than the removed getter. Parameterized
regressions seed an existing package with a slashless persisted URL and use an
explicit directory-hinted URL for rebasing before and after loading, lookup,
registration, removal, and no-op rebasing. They verify stable IDs, independent
persisted readback, and unchanged bytes/modification dates for no-ops. Registry
initialization, loading, write ownership, saving, and flushing are unchanged;
only the five registry location comparisons changed.

`Tests/CompositorProTests/Project/ProjectAccessibilityMCPTests.swift` exercises
production `MCPService.registerTools` through a real in-memory MCP client/server:

- Discover `manage_project` and inspect its action and selector schema.
- List isolated readable, missing, and permission-denied temporary packages;
  verify stable IDs, paths, names, accessibility, and project-state flags against
  independent filesystem inventory. Resolve known ID/name close selectors to
  those same paths without opening or closing a document.
- Reject invalid actions, selector types/combinations, and unknown IDs/names;
  verify unchanged registry bytes, package bytes, and recursive item inventory.
- Hold the injected accessibility check, change a registry URL, then release it;
  first require that the intended entry changed, then require a context-changed
  error and independently read the persisted new URL.
  Package bytes and inventory must remain unchanged.
- Cancel the pending MCP request, wait for the checker to finish, and verify no
  registry or package changes. Failure cleanup releases the gate, drains the
  checker, flushes the registry, and restores directory permissions before removal.

Fixtures perform all I/O on their dedicated actor. No production project or
registry files are used. Immediate SDK calls return content/error tuples; pending
calls use `RequestContext<CallTool.Result>` and the client's cancellation API.

Manual accessibility verification (supersedes the prior getter caveat below):

1. Use disposable readable, missing, and permission-denied projects. Cards show
   correct availability; selecting, removing, and deleting remain usable.
2. Remove or restore a project in Finder, then reactivate the app. Availability
   refreshes without duplicate body-time probes. Open and Reveal recheck paths.
3. Start an open/reveal check on a slow volume, then change selection, replace the
   entry URL, dismiss the card, or deactivate the app. No stale callback fires.
   Verify Escape, menu dismissal, focus, and return to the home window manually.
4. Via MCP, list an isolated project registry containing readable, missing, and
   unreadable paths; verify IDs, paths, open/active/visible flags, and accessibility.
   Change a registered URL or project focus during a delayed check; expect the
   explicit context-changed retry error, not an outdated success receipt.
   Resolve ID/name selectors immediately after startup; expect loaded entries,
   not a premature "No project" error. Path selectors must not wait on the registry.
5. Restore a previously missing disposable package, then open and Save As. Its
   registry ID remains stable; differing directory hints alone must not duplicate
   an entry or rewrite registry bytes.

The earlier 30-test isolated stub proof predates constructor injection, async
selector resolution, and this MCP suite; it does not verify the latest changes.
Main's initial focused integration exposed the directory-hint mismatch in registry
rebasing. Frozen focused gate 7 passed all 140 tests in 21 suites, including registry
directory-hint regressions, MCP stale-list refusal, discovery, independent readback,
and request cancellation. Frozen source hashes stayed unchanged. This supersedes
the implementing subagent's parser-only limitation. Frozen `tsan-1` subsequently
passed 137 tests in 19 suites, including registry/accessibility, without race
diagnostics and with unchanged hashes. Full-suite and final combined gates remain
pending. Native UI verification remains manual.

## Verification

`Tests/CompositorProTests/Media/ProjectRegistryTests.swift` uses unique temporary
directories, actor-isolated off-main fixture I/O, no sleeps, and no shared registry.
Coverage includes load replay ordering, stable IDs, no-op bytes and modification
dates, empty-file noncreation, latest-snapshot reload, corrupt-load preservation,
deterministic write failure/retry, caller cancellation, missing-project delete,
and deletion refusal after a failed load.

Focused proof was run in an isolated SwiftPM package containing exact copies of
the production registry and registry tests. Only `Project`/`Log` were stubbed:
the default storage accessor traps, and failure logging asserts off-main execution.
This proves registry behavior, not native document integration or the full app.
Main session owns repository builds, full tests, and Thread Sanitizer verification.

Manual UI verification remains required:

1. Open a disposable project; Save As; verify its recent-project ID remains stable
   and its URL survives relaunch. Check undo and document focus remain unchanged.
2. Start Save As, then request close, restart, or quit; expect final registry state
   to persist before the operation completes, without a main-thread wait.
3. Make the disposable registry destination unwritable; save and quit must surface
   failure rather than report success or exit silently. Repair it and retry.
4. Use a missing project and an empty registry; confirm selection, disabled/open
   states, Escape, and dismissal remain correct. Profile slow-volume checks before
   making responsiveness claims; accessor removal alone is not a measurement.
