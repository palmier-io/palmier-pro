# PalmierPro

AI-native macOS video editor. Swift 6.2, SwiftUI + AppKit, AVFoundation. macOS 26 only, arm64 only. Non-sandboxed Developer ID app.

## Build

```bash
swift build                         # dev
swift run PalmierPro                # run from CLI
scripts/bundle.sh                   # .app, unsigned
scripts/bundle.sh release --sign    # signed .app
scripts/bundle.sh release --dist    # signed + notarized + stapled DMG
```

No tests. `swift build` is the smoke check. Entry is `App/main.swift` (plain `NSApplication.run()`, no `@main`).

## Dependencies

- `fal-swift` — image/video/audio/upscale generation
- Anthropic HTTP API — chat agent (`Agent/AnthropicClient.swift`, direct HTTP, not the SDK)
- `swift-sdk` (MCP) — Palmier *exposes* its editor as an MCP server to external agents
- `DSWaveformImage` — audio waveform thumbnails
- `Sparkle` 2.7 — in-app auto-update; wired via `App/Updater.swift`

BYOK. fal key in a 0600 file in `~/.palmier/` (`Utilities/FileCredentialStore.swift`); Anthropic key in Keychain (`AnthropicKeychain` in `AgentService`).

## Architecture

### Document-based, one project = one window hierarchy

`VideoProject: NSDocument` is the unit of state. Each project owns its own `EditorViewModel` and optional `MCPService`. `AppState.shared` (`@Observable @MainActor`) only tracks `activeProject: VideoProject?` for menu-bar routing between the home window and editor windows. There is no app-wide editor singleton.

`VideoProject` reads/writes a `.palmier` **FileWrapper package** (`Project/VideoProject.swift`):
- `timeline.json` — `Timeline` struct (Codable)
- `media-manifest.json` — `MediaManifest` (id → source location)
- `.media/` — imported/generated media files
- `.sessions/` — per-chat-session JSON via `ChatSessionStore`
- `thumbnail.png` — captured on save

NSDocument reads happen off-main; the decoded `Timeline`/`MediaManifest` are stashed in `loadedTimeline`/`loadedManifest` with `nonisolated(unsafe)` and moved onto `EditorViewModel` in `makeWindowControllers()` on the main actor. Save mirrors this with `snapshotTimeline`/`snapshotManifest` captured on main before `fileWrapper(ofType:)` runs off-main. Autosave-in-place is enabled.

### Timeline model — everything is a value type

`Models/Timeline.swift`:
- `Timeline { fps, width, height, tracks: [Track] }`
- `Track { id, type: ClipType, clips: [Clip], muted, hidden, syncLocked, displayHeight (not serialized) }`
- `Clip { id, mediaRef: String, startFrame, durationFrames, trimStartFrame, trimEndFrame, speed, volume, opacity, transform, linkGroupId? }`

Frames, not seconds, are the canonical time unit. `mediaRef` is an ID into `MediaManifest`, not a path. `linkGroupId` pairs video+audio clips from the same source. `Transform` is normalized 0–1 canvas space (center-based storage with `topLeft` helpers). `Track.contiguousClipIds(fromEnd:excludeId:)` walks a snap-adjacent chain — used by ripple edits.

### EditorViewModel is a grab bag, intentionally

`Editor/ViewModel/EditorViewModel.swift` is the main `@Observable @MainActor` held by the document. It holds both persisted state (`timeline`, `mediaManifest`) and all transient UI state (`currentFrame`, `selectedClipIds`, `zoomScale`, `toolMode`, `pendingReplacements`, `previewTabs`, etc.). It's split across extension files:

- `+ClipMutations.swift` — move, trim, split (each registers undo on the document's `undoManager`)
- `+Ripple.swift` — ripple-delete / ripple-move
- `+Linking.swift` — video/audio link groups
- `+MediaLibrary.swift` — manifest operations
- `+Tracks.swift` — track add/remove/reorder
- `+PreviewTabs.swift` — multi-tab preview (timeline + source viewers)
- `+ProjectSettings.swift` — fps/resolution migration

Views get it via `.environment(editorViewModel)`. No `EnvironmentObject`, no singletons.

### Timeline rendering is AppKit, not SwiftUI

`Timeline/TimelineView` is an `NSView`; drawing goes through `ClipRenderer` / `PlayheadRenderer` / `TimelineRuler` (stateless draw helpers). `TimelineGeometry` is a pure struct snapshotted per layout — precomputed `cumulativeY` for O(1) hit testing, plus `frameAt(x:)` / `trackAt(y:)` / `clipRect(...)`. `TimelineInputController` owns the drag state machine (`DragState` enum): during a drag it accumulates a delta without mutating `EditorViewModel`, then commits on mouse-up. `SnapEngine` is pure — it probes clip edges and playhead against candidate targets with sticky hysteresis. `ClipGeneratingOverlay` is hosted via `NSHostingView` keyed by clip id in `pendingReplacementOverlays`.

### Edit engines are pure

`Editor/RippleEngine.swift` and `OverwriteEngine.swift` are `enum`s with static methods. They take the current state plus an intent and return a plan — `[ClipShift]` or `[Action]` — that the caller applies. They never mutate.

### Preview = AVComposition rebuild on edit

`Preview/CompositionBuilder.swift::build(timeline:manifest:)` is `async static` and constructs an `AVMutableComposition` + `AVAudioMix` + `trackMappings` from the current timeline. Images become videos via `ImageVideoGenerator.stillVideo()`. `VideoEngine` (`@Observable @MainActor`) wraps an `AVPlayer`, holds a `rebuildTask: Task<Void, Never>?`, and cancels-and-restarts on each change so rapid edits coalesce. `player.replaceCurrentItem()` swaps in the new composition.

### Generation

`Generation/GenerationService.swift` is the one code path for all AI media: image, video, audio, upscale, edit, rerun. Flow: create a placeholder `MediaAsset` with `generationStatus = .generating`, upload reference files to fal, poll the endpoint, download the result into `.media/`, snapshot the full input into the asset's `generationInput` (enables rerun), flip status to `.none`. Model definitions live in `Generation/Fal/*ModelConfig.swift` — each owns its endpoint name and input-dict builder.

`Inspector/AIEditTab.swift` + `Generation/Edit/EditSubmitter.swift` drive per-clip edits (Upscale / Edit / Rerun). Setting `replaceClipSource` on `EditorViewModel.pendingEditReplacementClipId` makes the completed generation swap the clip's `mediaRef` in place (the `ClipGeneratingOverlay` is shown for that clip id meanwhile).

### Agent + MCP

`Agent/AgentService.swift` (`@Observable @MainActor`) is the chat agent: per-project sessions, Anthropic tool-use loop, streaming. Tools are declared in `Agent/Tools/ToolDefinitions.swift` and dispatched by `Agent/Tools/ToolExecutor.swift`, which mutates `EditorViewModel` directly.

`Agent/MCP/MCPHTTPServer.swift` is an `actor` wrapping `NWListener` that speaks HTTP MCP (stateless transport) — **this exposes Palmier's editor tools to external agents**, not the other way around. Each TCP connection gets its own `Server` + `StatelessHTTPServerTransport` pair. Same `ToolDefinitions` are re-used on both sides.

## Concurrency & patterns

- Major stateful types are `@Observable @MainActor` (`AppState`, `EditorViewModel`, `VideoEngine`, `AgentService`, `ProjectRegistry`). No `ObservableObject`.
- `NSDocument` read/save run off-main → `nonisolated(unsafe)` bridge fields, hop to main to apply.
- Undo is always the NSDocument's `undoManager`. Mutations in `EditorViewModel+*` register their own inverses; don't commit to `timeline` without going through those helpers.
- `Utilities/Log.swift` — categorized `os.Logger` (`Log.project`, `Log.mcp`, etc.) plus a signal handler writing to `~/Library/Logs/PalmierPro/crash.log`.
- `Utilities/AppTheme.swift` — static colors/metrics, compile-time.
- `Utilities/Constants.swift` has `Project.fileExtension`, `Project.storageDirectory`, filename constants.

## Releases & auto-update (Sparkle)

Signed + notarized DMGs via `scripts/bundle.sh release --dist`. Per release:

1. Bump `CFBundleShortVersionString` + `CFBundleVersion` in `Resources/Info.plist`.
2. `./scripts/bundle.sh release --dist` — prints the `sparkle:edSignature` and DMG length.
3. Tag `vX.Y.Z`, push, `gh release create … PalmierPro.dmg`.
4. Add an `<item>` to `appcast.xml` at repo root using the signature from step 2; commit + push.

Appcast feed: `https://raw.githubusercontent.com/palmier-io/palmier-pro/main/appcast.xml` (~5 min cache).

EdDSA private key lives in the login Keychain under `https://sparkle-project.org`. **Don't regenerate** — losing it means installed users can never receive another signed update.