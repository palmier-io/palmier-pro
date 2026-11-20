# Developer agent guide

This guide tunes coding-agent work, not the app's filmmaking prompts or project data. Read it for unfamiliar ownership; do not preload the whole documentation tree.

## Instruction layout

- `AGENTS.md` is the always-on contract and behavioral router. `CLAUDE.md` imports it; do not maintain a second copy.
- `docs/agents/rules/` contains canonical on-demand engineering policy. Select by affected behavior, including callers, not just edited paths.
- `.cursor/rules/` contains short file-scoped dispatchers pointing to that policy. Globs aid discovery; they do not exempt behavior outside their directories.
- `.agents/skills/` contains portable coding workflows. OpenCode discovers these project skills; if a harness does not advertise them, read the linked `SKILL.md` directly.
- `.cursor/BUGBOT.md` owns review priorities and finding quality. Domain details stay in the canonical rules.
- Do not globally inline all rules with a configuration wildcard, duplicate skills under multiple harness directories, or weaken verification to save tokens.
- App runtime skills live separately in `Sources/CompositorPro/Agent/Skills/`; `__agent__/` holds project planning data. Neither is a destination for developer guidance.

## Owner-first navigation

Start with a user-named file/symbol when available. Otherwise choose the owning route below, find the specific capability, then follow actual callers. Read `Package.swift` for supported traits/dependencies; use `Package.resolved` and installed checkout docs for version-sensitive APIs.

### Editorial state and undo

- Owner: `Sources/CompositorPro/Editor/ViewModel/EditorViewModel.swift`; capability implementations: `Sources/CompositorPro/Editor/ViewModel/EditorViewModel+*.swift`.
- Shared operations: `Sources/CompositorPro/Editor/ClipPlacement.swift`, `Sources/CompositorPro/Editor/RippleEngine.swift`, `Sources/CompositorPro/Editor/OverwriteEngine.swift`, and `Sources/CompositorPro/Editor/EditorUndo.swift`.
- Persisted clip/track/timeline models: `Sources/CompositorPro/Models/Timeline.swift`; timing maps: `Sources/CompositorPro/Models/SourceTimeMap.swift`.
- Tests: `Tests/CompositorProTests/Editor/`, `Tests/CompositorProTests/Timeline/`, and the corresponding Agent tool suites. Example filter: `EditorUndoTests|UndoToolTests|ClipIdentityMCPTests`.

### Agent tools and MCP

- Schema/catalog: `Sources/CompositorPro/Agent/Tools/ToolDefinitions.swift`; dispatch/session binding: `Sources/CompositorPro/Agent/Tools/ToolExecutor.swift`; capabilities: matching `ToolExecutor+*.swift` in that directory.
- Protocol adapter: `Sources/CompositorPro/Agent/MCP/MCPService.swift`; HTTP/session transport: `Sources/CompositorPro/Agent/MCP/MCPHTTPServer.swift`.
- In-app Agent and external MCP share the executor/domain operations. External MCP has session-bound project checks; do not replace them with silent frontmost-project retargeting.
- Tests: `Tests/CompositorProTests/Agent/`. Protocol examples: `ClipIdentityMCPTests`, `SwapClipMediaToolTests`, and `ProjectPackageImportMCPTests`; HTTP notification coverage: `MCPToolListAnnouncementTests`.
- Fixture graph: `Tests/CompositorProTests/Fixtures.swift` and `Tests/CompositorProTests/Agent/ToolExecutorTests.swift`. Do not copy legacy `ToolHarness.addAsset` main-actor stub-file I/O; use off-main package/media support instead.

### Documents, media installation, and generation

- Document/save/close owner: `Sources/CompositorPro/Project/VideoProject.swift`.
- Admission/fences: `Sources/CompositorPro/Project/ProjectPackageCoordinator.swift`; serial filesystem executor: `Sources/CompositorPro/Project/ProjectPackageIO.swift`; project index: `Sources/CompositorPro/Project/ProjectRegistry.swift`.
- Generation lifecycle: `Sources/CompositorPro/Generation/`; manifests and media identity: `Sources/CompositorPro/Models/MediaManifest.swift` and `Sources/CompositorPro/Media/`.
- Contracts: `docs/contracts/project-package-lifecycle.md`, `docs/contracts/project-close-confirmation.md`, `docs/contracts/project-media-undo-rebase.md`, and `docs/contracts/generation-lifecycle.md`.
- Tests: `Tests/CompositorProTests/Project/`, `Tests/CompositorProTests/Generation/`, `Tests/CompositorProTests/Agent/ProjectPackageImportMCPTests.swift`, and `Tests/CompositorProTests/Media/ProjectRegistryTests.swift`.
- Off-main disposable packages and deterministic signals: `Tests/CompositorProTests/Project/ProjectPackageTestSupport.swift`. Example filter: `ProjectPackageCoordinatorTests|ProjectPackageInstallTests|ProjectPackageSaveAsTests|ProjectPackageImportMCPTests`.

### Rendering, playback, export, and audio

- Rendering: `Sources/CompositorPro/Compositing/`; playback: `Sources/CompositorPro/Preview/`; export orchestration: `Sources/CompositorPro/Export/ExportQueue.swift` and `Sources/CompositorPro/Export/ExportService.swift`.
- Delivery: `Sources/CompositorPro/Delivery/`; audio/analysis: `Sources/CompositorPro/Audio/`; transcription: `Sources/CompositorPro/Transcription/`; search/indexing: `Sources/CompositorPro/Search/`.
- Tests: corresponding `Compositing`, `Rendering`, `Export`, `Audio`, `Transcription`, `Search`, and `Index` directories under `Tests/CompositorProTests/`. Directory similarity is a starting point, not proof of coverage.
- Preserve exact media semantics and explicit executor/cache contracts. Speech and AWS changes require their optional trait gates.

### Native UI, copy, and resources

- Shared styling: `Sources/CompositorPro/UI/AppTheme.swift`; localization API/boundary: `Sources/CompositorPro/Localization/AppLocalization.swift` and `Sources/CompositorPro/Localization/UILocalization.swift`.
- Native editor shell: `Sources/CompositorPro/Editor/EditorView.swift` and `Sources/CompositorPro/Editor/EditorWindowController.swift`; feature panels live with their feature.
- Parent drop-area example: `Sources/CompositorPro/MediaPanel/MediaTab/MediaPanelDropArea.swift`.
- Shared resource lookup: `Sources/CompositorPro/Utilities/BundledResource.swift`; inventory: `Package.swift`; packaging: `scripts/bundle.sh`; app launch/log helper: `scripts/dev.sh`.
- Copy generation/validation: `scripts/localization/sync.sh` and `scripts/localization/check.mjs`; tests: `Tests/CompositorProTests/Localization/` and affected UI/model suites.
- UI checks are manual and use a disposable project. Do not launch the user's restored editor or mutate its MCP endpoint as automated test setup.

### HyperFrames and CLI integration

- App integration: `Sources/CompositorPro/Hyperframes/`; tool adapter: `Sources/CompositorPro/Tools/AdapterImport/`; command dispatch: `Sources/CompositorPro/CLI/CLIHandler.swift`.
- Tests: `Tests/CompositorProTests/Hyperframes/` and `Tests/CompositorProTests/CLI/`.
- Read `docs/HeadlessRendering.md` for headless output and `docs/adoption.md` for integration context. Load video-authoring skills only when the task actually creates/edits a composition or video.

## Keep guidance reliable

Run from the repository root with Python 3.9+; scripts use only the standard library:

```sh
python3 -B scripts/agents/check.py
python3 -B -m unittest discover -s scripts/agents -p 'test_*.py'
git diff --check
```

The checker validates local references, root routing, skill metadata/discoverability, dispatcher globs, and size budgets. It does not prove code correctness, automatic skill selection, UI behavior, or faster task execution.

When a feature moves, update its navigation/reference and run the checker. Keep root instructions within the context budget, policies focused, and skills task-specific. Add guidance for observed failure modes, not hypothetical ones.
