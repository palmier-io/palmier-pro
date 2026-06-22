# Intel Editor-Only Status

This branch contains an experimental Intel Mac editor-only build mode for Palmier Pro.
It is not official Palmier support, and it has not been proven to launch on Intel
hardware until the GitHub Actions build passes and the resulting app is tested.

The normal Palmier Pro build path is unchanged when `PALMIER_EDITOR_ONLY` is not
set: it remains the full macOS 26 Apple Silicon build with the normal backend and
AI features.

## Build Mode

Enable the experimental mode with:

```bash
PALMIER_EDITOR_ONLY=1
```

In this mode, `Package.swift` lowers the package platform target to macOS 15.0,
defines `PALMIER_EDITOR_ONLY`, and removes Clerk/Convex backend package products
from the SwiftPM dependency graph.

Local SwiftPM build command:

```bash
PALMIER_EDITOR_ONLY=1 swift build --arch x86_64
```

Local debug app bundle command:

```bash
PALMIER_EDITOR_ONLY=1 SIGNING_IDENTITY=- SWIFT_BUILD_ARGS="--arch x86_64" ./scripts/bundle.sh debug --fast
```

This creates `.build/PalmierPro.app` using ad-hoc signing. It does not notarize
the app, install it globally, use Apple IDs, or use signing certificates.

## Disabled Features

The following features are disabled or stubbed only when `PALMIER_EDITOR_ONLY=1`:

- Palmier account login, Clerk sessions, subscriptions, billing, credits, and plan management.
- Convex/ConvexMobile backend subscriptions, mutations, storage tickets, and hosted model catalog sync.
- Generative AI submission, rerun, upscale, download, and hosted generation job updates.
- Hosted Palmier agent streaming that depends on Clerk/Convex authentication.
- On-device Speech framework transcription and automatic caption generation from audio.
- Backend-dependent feedback submission.

Disabled feature paths should report:

```text
This feature is unavailable in the experimental Intel editor-only build.
```

The intended first working surface is the local editor core: project open/save,
timeline editing, media import, preview/export, local resources, and local MCP or
BYOK paths that do not require Palmier's hosted backend.

## Known Risks

- The branch requires a Swift 6.2-capable toolchain and macOS 26 SDK to compile
  guarded macOS 26 SwiftUI APIs, even though the editor-only package target is
  macOS 15.0.
- The GitHub Actions runner can prove compilation and artifact assembly, but it
  does not prove launch behavior on a 2019 Intel iMac running macOS 15.7.7.
- The uploaded app artifact is ad-hoc signed and not notarized.
- More macOS 26-only API calls may still exist and only surface after the next
  compiler pass.
- Dependencies such as Sparkle, Lottie, Sentry, MCP, and swift-transformers still
  need the runner to confirm x86_64 compatibility in this package shape.
- Runtime behavior around Core ML model downloads, local visual search, export,
  and media frameworks still needs real Intel hardware testing.

## GitHub Actions

Workflow:

```text
.github/workflows/intel-editor-only-build.yml
```

It can be run from GitHub:

1. Open the fork on GitHub.
2. Go to Actions.
3. Select "Intel Editor-Only Build".
4. Select "Run workflow".
5. Choose branch `intel-mac-support-experiment`.

The workflow also runs on pushes to `intel-mac-support-experiment`, except for
Markdown-only changes.

The workflow runs:

```bash
PALMIER_EDITOR_ONLY=1 swift package --disable-dependency-cache --scratch-path .build/editor-only --manifest-cache local resolve
PALMIER_EDITOR_ONLY=1 swift build --disable-dependency-cache --scratch-path .build/editor-only --manifest-cache local --arch x86_64
PALMIER_EDITOR_ONLY=1 swift test --disable-dependency-cache --scratch-path .build/editor-only --manifest-cache local --arch x86_64
```

If the build or tests fail, the workflow uploads:

```text
intel-editor-only-swiftpm-logs
```

If the build and tests pass, the workflow assembles and uploads:

```text
palmier-pro-intel-editor-only-app
```

That artifact should contain:

```text
PalmierPro-intel-editor-only.app.zip
```

