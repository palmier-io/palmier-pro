# Palmier Pro Fork Engineering Notes

This is a living note for the BrowningL fork. Keep it focused on details that help an agent make correct edits, build the local app, and avoid breaking persistence.

## How Agents Should Use This File

- Read this file before changing editor models, timeline UI, inspector controls, render/compositing code, effects, project persistence, or agent/MCP tools.
- Update this file in the same commit when adding or changing a custom fork feature.
- Keep entries factual and compact: feature id/model field, where the user finds it, how the agent uses it, how it persists, what tests cover it, and any install caveats.
- Treat persistence as a first-class requirement. A feature is not complete just because it appears in the UI during the current app session.

## Local Workflow

- Main working branch for the current custom editor work: `feature/clip-blend-modes`.
- Remote fork: `origin` points at `https://github.com/BrowningL/palmier-pro.git`.
- Upstream contributions are optional. For local use, commit and push to the fork so the upgraded app is not blocked by maintainer review.
- Do not assume a new build is what the user has open. A running `PalmierPro.app` process keeps using the binary it launched with until the app is fully quit and reopened.

## Build, Test, and Install

Standard development:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Bundled debug app:

```bash
./scripts/dev.sh --no-stream
```

Install the current debug binary into the local patched app bundles:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
SRC="$PWD/.build/arm64-apple-macosx/debug/PalmierPro"
RES_BUNDLE="$PWD/.build/arm64-apple-macosx/debug/PalmierPro_PalmierPro.bundle"

for APP in "/Applications/PalmierPro.app" "$HOME/Applications/PalmierPro-BlendModes.app"; do
  test -d "$APP" || continue
  DEST="$APP/Contents/MacOS/PalmierPro"
  cp "$SRC" "$DEST"
  cp "$RES_BUNDLE"/*.metallib "$APP/Contents/Resources/"
  if ! otool -l "$DEST" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath '@executable_path/../Frameworks' "$DEST"
  fi
  codesign --force --deep --sign - "$APP"
  codesign --verify --deep --strict "$APP"
done
```

After installing, fully quit and reopen Palmier Pro. Do not force quit if the user may have unsaved project state.

Useful checks:

```bash
git status --short --branch
pgrep -fl 'PalmierPro|palmier' || true
```

## Core Architecture

- `Sources/PalmierPro/Models/Timeline.swift` is the project timeline model. Persistent timeline fields belong here and must be `Codable`.
- `Sources/PalmierPro/Project/VideoProject.swift` is the `NSDocument` bridge. Save writes `editorViewModel.timeline` into the `.palmier/project.json` package. Reopen reads the same JSON back into `loadedTimeline` and applies it in `makeWindowControllers()`.
- `Sources/PalmierPro/Editor/ViewModel/` owns editor mutations, undo registration, dirty-state notification, media state, and timeline helper APIs.
- `Sources/PalmierPro/Timeline/TimelineView.swift` draws the timeline and handles direct timeline interactions.
- `Sources/PalmierPro/Inspector/InspectorView.swift` contains the main clip inspector controls.
- `Sources/PalmierPro/Preview/CompositionBuilder.swift` builds AVFoundation compositions for preview/export.
- `Sources/PalmierPro/Compositing/CustomVideoCompositor.swift` and `Sources/PalmierPro/Compositing/FrameRenderer.swift` render custom visual compositing.
- `Sources/PalmierPro/Agent/Tools/` defines MCP/in-app agent tools, schemas, executors, and agent-facing instructions.

## Persistence Rules

For any feature that should survive save, quit, and reopen:

1. Store it in a `Codable` model that is encoded by `Timeline`, `MediaManifest`, or another document package file.
2. Add a decoding default for old projects if the field is new.
3. Mutate it through `EditorViewModel` APIs, not by editing UI-local state only.
4. Register undo where appropriate.
5. Call the document dirty path for every persistent edit.
6. Add a model round-trip test and a `VideoProject.write(...)` package test when the feature affects project files.

If the feature can be controlled from the inspector and from the agent, both paths should hit the same model/editing API. Do not keep a parallel UI-only representation.

For effects, prefer the existing `Clip.effects` model and `EffectRegistry` descriptor path. That makes inspector controls, rendering, persistence, and `apply_effect` validation share one effect id and parameter schema. A new effect usually should not need a bespoke tool unless it has behavior beyond setting effect parameters.

The dirty path is:

```text
editor mutation
-> EditorViewModel.markDocumentEdited()
-> EditorViewModel.onDocumentEdited
-> VideoProject.updateChangeCount(.changeDone)
-> NSDocument autosave/save knows the package changed
```

Do not suppress future dirty notifications just because `editorViewModel.isDocumentEdited` is already true. Autosave can save while the document remains open, and later edits still need to notify `NSDocument`.

Current package-level persistence regression:

- `Tests/PalmierProTests/Media/ProjectDocumentIOTests.swift`
- `editorMarkerAndBlendModePersistIntoProjectPackage`

## Agent and MCP Feature Wiring

If the Palmier AI or MCP clients need to use a new feature, update all relevant layers:

- `ToolDefinitions.swift`: tool schema, enum values, descriptions, required fields.
- `ToolExecutor+*.swift`: argument decoding, validation, mutation call, JSON result.
- `ToolExecutor+InspectTimeline.swift` and timeline serialization helpers when the agent must see the new state.
- `AgentInstructions.swift`: concise guidance for when and how the agent should use the feature.
- `AgentMentionContext.swift`: include fields that should be visible when clips or markers are mentioned.
- `Tests/PalmierProTests/Agent/ToolExecutorTests.swift`: accepted input, rejected input, state changes, and dirty notification.

The app exposes the same tool definitions to the in-app agent and MCP service, so correct tool wiring is what lets external agents and Palmier's own AI recognize the feature.

Effects are the main exception to hand-editing every tool schema: `apply_effect` is driven by `EffectRegistry.all`, and `ToolExecutor` validates effect ids and params against that registry. For a normal effect, add the descriptor, inspector controls if needed, render implementation, agent instructions, and an `apply_effect` test.

## Current Custom Features

### Clip Blend Modes

- Model: `Sources/PalmierPro/Models/ClipBlendMode.swift`
- Clip field: `Clip.blendMode` in `Sources/PalmierPro/Models/Timeline.swift`
- Inspector UI: `InspectorView.blendModeRow(...)`
- Rendering: `FrameRenderer.composite(... blendMode:)`
- Agent tool: `set_clip_properties` accepts `blendMode`.
- Tests: `ProjectRoundTripTests`, `CompositorRenderTests`, `ToolExecutorTests`, `ProjectDocumentIOTests`.

Use `difference` with a white logo PNG to invert the background through the logo alpha. Use `exclusion` for a softer inversion.

### Timeline Markers

- Model: `TimelineMarker` and `Timeline.markers` in `Timeline.swift`
- Editor APIs: `EditorViewModel+Markers.swift`
- Timeline UI: marker drawing, context menu, rename/delete/go-to handlers in `TimelineView.swift`
- Agent tools: `add_markers`, `set_marker_properties`, `remove_markers`
- Tests: `ProjectRoundTripTests`, `ToolExecutorTests`, `ProjectDocumentIOTests`

Markers are exact project-frame anchors. They do not render and do not lengthen exports.

### Luma Key

- Effect id: `key.luma`
- Metal kernel: `Metal/LumaKey.metal`
- Swift wrapper: `Sources/PalmierPro/Compositing/Kernels/LumaKeyKernel.swift`
- Registry/UI: `EffectRegistry.swift`, `Inspector/Tabs/AdjustTab.swift`
- Agent tool: `apply_effect` accepts `type: "key.luma"` with `threshold` and `softness`.
- Persistence: stored as a normal `Clip.effects` entry, so it saves with the clip rather than inspector-local state.
- Install caveat: `LumaKey.metallib` must be copied from `PalmierPro_PalmierPro.bundle` into the app bundle resources when installing a patched binary.
- Tests: `LumaKeyKernelTests`, `CompositorRenderTests`, `EffectTests`, `ToolExecutorTests`.

Use this for simple white-background removal. Start with `threshold: 0.85` and `softness: 0.08`; lower the threshold to remove more near-white pixels, raise it to preserve bright subject details.

## Feature Checklist

Before calling a feature complete:

- Model field is persisted with a backward-compatible decode default.
- UI edits, agent edits, and undo/redo all go through shared editor mutation APIs.
- Persistent edits mark the document dirty.
- Save/reopen behavior is covered when the feature stores new project state.
- Preview and export share the same rendering path or both are updated deliberately.
- Custom Metal kernels are included in installed app resources and verified in the patched app bundle.
- The inspector uses `AppTheme` constants rather than hardcoded design values.
- The agent can inspect and mutate the feature if the user expects AI control.
- `docs/fork-engineering-notes.md` is updated with the final implementation shape.
- Focused tests pass.
- Full `swift test` passes.
- Patched app bundle is installed, signed, and reopened.
