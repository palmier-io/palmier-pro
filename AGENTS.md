# PalmierPro

AI-native macOS video editor. Swift 6.2, SwiftUI + AppKit, AVFoundation. macOS 26 only, arm64 only. Non-sandboxed Developer ID app.

## Build

```bash
swift build
swift run
```

## Code style

- Keep comments minimal. Only write one when the *why* is non-obvious. Don't restate what the code does, don't narrate the current change, don't leave `// removed X` breadcrumbs. One short line max — no multi-line comment blocks or paragraph docstrings.

## Design System

All UI styling MUST use `AppTheme` constants from `Sources/PalmierPro/UI/AppTheme.swift`. Never use hardcoded numeric values for:

- **Spacing/padding** → `AppTheme.Spacing.*` (xxs through xxl)
- **Font sizes** → `AppTheme.FontSize.*` (xxs through display)
- **Font weights** → `AppTheme.FontWeight.*` (regular, medium, semibold, bold)
- **Corner radii** → `AppTheme.Radius.*` (xs through xl)
- **Border widths** → `AppTheme.BorderWidth.*` (hairline, thin, medium, thick)
- **Opacity** → `AppTheme.Opacity.*` (subtle, faint, muted, medium, strong, prominent)
- **Icon frame sizes** → `AppTheme.IconSize.*` (xs through xl)
- **Shadows** → `AppTheme.Shadow.*` (sm, md, lg) via `.shadow(AppTheme.Shadow.md)`
- **Colors** → `AppTheme.Text.*`, `AppTheme.Border.*`, `AppTheme.Background.*`
- **Animation durations** → `AppTheme.Anim.*`

If a needed value doesn't exist in AppTheme, add it there first — don't hardcode it.

## Drag and drop

SwiftUI `.onDrop` on a parent view shadows every drop target inside its layout area on macOS 26 — even AppKit `NSDraggingDestination` children registered directly with the window. Inner `.onDrop` modifiers silently never fire while a parent `.onDrop` is active.

Rule: **any drop target that spans an area containing other drop targets must use native AppKit** (see `MediaPanelDropArea` in `Sources/PalmierPro/MediaPanel/`). Inner / leaf drops can stay SwiftUI `.onDrop`. Do not stack SwiftUI `.onDrop` modifiers in parent/child layouts.

## Voice

Palmier Pro speaks like a quietly capable native Mac app for filmmakers: direct, technical, calm, and 
confident. Prefer Apple HIG-style terseness over warmth. Never chatty or cute. Never marketing. When the
product needs to ask for action, lead with the action verb; when it reports state, name the thing.

## Cursor Cloud specific instructions

This project **cannot be built, run, or tested on the Cursor Cloud VM**, which is Linux/x86_64. PalmierPro is a macOS-only GUI app: `Package.swift` pins `.macOS(.v26)` (Tahoe) on Apple Silicon, ~150 source files import Apple-only frameworks (`AppKit`, `SwiftUI`, `AVFoundation`, `Metal`, `Cocoa`), the SPM dependencies (`Sparkle`, `sentry-cocoa`, `clerk-ios`, `lottie-ios`) are Apple-platform-only, the `MetalCIKernelPlugin` build tool needs Apple's Metal toolchain, and `scripts/bundle.sh`/`scripts/dev.sh` rely on `codesign`, `install_name_tool`, `dsymutil`, `xcrun`, `hdiutil`, and `PlistBuddy`.

Consequences for cloud agents:
- `swift build` / `swift run` / `swift test` will fail on Linux even if a Swift toolchain is installed — `import AppKit` and the macOS-only packages do not resolve there. The test target depends on the main target, so nothing in `Tests/` is Linux-testable either.
- There is no useful dependency install step for this repo on Linux; the startup update script is intentionally a no-op.
- Lint/build/run/test must be done on a macOS 26 + Xcode 16 + Swift 6.2 machine using the commands in `CONTRIBUTING.md` (`swift build`, `swift run`, `swift test`, `./scripts/dev.sh`). Make code-only changes here and verify them on macOS.

