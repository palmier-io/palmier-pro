# Palmier Pro for Linux

Ubuntu 26.04 x86_64 Tauri build of Palmier Pro. The Swift macOS app remains the behavioral oracle. Linux opens and resaves current `.palmier` packages without changing their meaning.

## Status vs the port plan

The scaffold and shared service path from the Linux editor port plan are in place under `linux/`. Most stages have working code and automated tests. It is **not** fully done and verified end to end against every plan gate.

### Implemented

| Area | What landed |
|------|-------------|
| Workspace | Pinned Rust 1.97.1 workspace, crates, Tauri app, bootstrap script, Linux CI (`.github/workflows/linux.yml`) |
| Models / I/O | Compatible project models, atomic package save/open, import, media probe, coordinator lifecycle |
| Edits | Shared `EditorCommand` path, overwrite/ripple rules, receipts, undo/redo, revisioned preview/commit |
| UI shell | React home + editor (Media, Preview, Inspector, Timeline), AppTheme tokens, locale sync for en/es/fr |
| Preview / media | FFmpeg decode, composition plan, project frame render, optional wgpu compositor, caches, JPEG preview frames to UI |
| Export | Staged FFmpeg export queue, codec capability checks, export UI, timeline XML / package Save As paths |
| MCP | Loopback `http://127.0.0.1:19789/mcp`, protocol `2025-06-18`, tools routed through `EditorServiceBackend` |
| Generation | Fal / Replicate BYOK via Secret Service only (no plaintext app fallback), catalog, mock HTTP tests, MCP generation tools |
| Packaging assets | Desktop entry, MIME XML, icons, CI `.deb` job |

### Recently completed

- Clip **slip** (`SlipClips`), **speed** (`SetClipSpeed`), and **fades** (`SetClipFades`) in `palmier-core`, wired through the inspector and MCP.
- Session **track lock** in the React UI (not persisted in `.palmier`; macOS packages have no track-lock field).
- Timeline **audio mixing** for H.264/AAC export via PCM decode + mix in `ProjectFrameSource`.
- MCP **`capture_frame` / `export_project` / `manage_exports`** on `EditorServiceBackend` when built with `palmier-mcp` feature `media` (enabled by the Tauri app).

### Remaining gaps

- **Specta-generated TypeScript bindings** were skipped. Hand-written bindings live in `app/src/bindings/` (specta / tauri-specta version mismatch).
- **wgpu / cpal** remain optional. Preview audio playback and GPU compose are not the default verified path on every host.
- Timeline **slip gesture** in the React timeline UI is not finished. The Rust command exists for MCP and future UI wiring.
- **`.deb` install into a clean Ubuntu image** was not completed on this development host. CI defines the package job.
- **Full plan clippy gate** (`-D warnings`) is relaxed in CI to correctness + suspicious only, and `palmier-app` is excluded from workspace tests.
- **Manual UI e2e** is not user-confirmed.
- **macOS Swift fixture CI** exists as `Tests/PalmierProTests/LinuxFixtureCompatibilityTests.swift` but cannot run on this Linux host.

### Architecture

```text
React UI  -->  Tauri commands  -->  EditorService / ProjectActor
MCP client -->  MCP HTTP server -->  EditorServiceBackend --> EditorService
ProjectActor owns mutable project state.
Blocking I/O, FFmpeg, provider HTTP, and keyring run off the actor.
```

## Requirements

- Ubuntu 26.04 x86_64 (Resolute Raccoon)
- Distro FFmpeg 8 shared libraries (`libav*`)
- GTK 3 + WebKitGTK 4.1 (Tauri)
- Secret Service / libsecret for BYOK provider keys
- Node.js 22+
- Rust 1.97.1 (see `rust-toolchain.toml`)

## Bootstrap

From the repo:

```bash
cd linux
sudo ./scripts/bootstrap-ubuntu-26.04.sh
```

If system `-dev` packages are missing and you use a local sysroot under `linux/.deps/`, source the helper env (do **not** export that sysroot into `LD_LIBRARY_PATH` while compiling, or rustc can break):

```bash
cd linux
source ./scripts/env.sh
```

When running tests that need the sysroot’s shared libs at runtime:

```bash
export LD_LIBRARY_PATH="${PALMIER_RUN_LD_LIBRARY_PATH:-}:${LD_LIBRARY_PATH:-}"
```

## Build and test (Rust)

Always work from `linux/`:

```bash
cd linux
cargo fmt
cargo clippy --workspace --exclude palmier-app --all-targets -- -D clippy::correctness -D clippy::suspicious
cargo test --workspace --exclude palmier-app
cargo check -p palmier-app
```

Useful focused suites:

```bash
cargo test -p palmier-core
cargo test -p palmier-project
cargo test -p palmier-media --lib
cargo test -p palmier-mcp
cargo test -p palmier-generation
cargo test -p palmier-service
```

## Build and test (frontend)

```bash
cd linux/app
npm ci
npm run lint
npx tsc -b --pretty false
npm test
npm run build
```

Sync macOS localization catalogs into JSON (en/es/fr and friends):

```bash
cd linux/app
npm run sync-locales
```

## Run the desktop app

Development (Vite + Tauri):

```bash
cd linux/app
npm ci
npm run tauri:dev
```

Browser-only demo mode (no Tauri, local demo backend):

```bash
cd linux/app
npm run dev
```

Production binary after build:

```bash
cd linux/app
npm run tauri:build
# binary under src-tauri/target/release/
```

Open a project from the home screen, or pass a `.palmier` directory once CLI opening is wired in your local build.

While the app is running, MCP listens at:

```text
http://127.0.0.1:19789/mcp
```

## Package `.deb`

```bash
cd linux/app
npm ci
npm run tauri:build -- --bundles deb
```

Artifact path (typical):

```text
linux/app/src-tauri/target/release/bundle/deb/*.deb
```

Install on Ubuntu 26.04 and confirm FFmpeg 8 + Secret Service are present on the target machine.

## Workspace crates

| Crate | Role |
|-------|------|
| `palmier-core` | Models, overwrite/ripple, edit commands, receipts, undo |
| `palmier-project` | Package I/O, import, registry, coordinator |
| `palmier-media` | FFmpeg probe/decode/export, plan, caches, optional wgpu/cpal |
| `palmier-service` | `EditorService` / `ProjectActor`, revisioned preview/commit |
| `palmier-mcp` | Loopback MCP HTTP server + `EditorServiceBackend` |
| `palmier-generation` | Fal / Replicate BYOK jobs |
| `app/src-tauri` (`palmier-app`) | Tauri binary, commands, UI host |

## Manual verification checklist

Use an isolated temporary `.palmier` project:

1. Create / open / save / reopen
2. Import video, audio, and image
3. Split, trim, move, delete, undo, redo
4. Preview a paused frame and scrub
5. Export H.264 (video-only timeline until audio mix lands)
6. MCP: list tools, mutate, read back, undo
7. Settings: set Fal or Replicate key via Secret Service, run a generation job (or confirm actionable error if keyring is missing)
8. Quit while export or generation is active and confirm no package corruption

Do not treat UI verification as complete until those steps are confirmed on a real Ubuntu 26.04 desktop session.
