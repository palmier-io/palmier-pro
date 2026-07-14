# PalmierPro — Windows

WinUI 3 + C#/.NET port of PalmierPro. .NET 10, Windows App SDK 1.8.x, native C++
rendering engine (`PalmierEngine.dll`) behind a flat C ABI. This file governs
`platforms/windows/`; the root `AGENTS.md` covers the Mac app (Swift/SwiftUI) and is
otherwise unrelated to this tree.

## Build

See `docs/README.md`. Short version: native engine via `msbuild` (not `dotnet`,
which can't build `.vcxproj` — MSB4278), then `dotnet build PalmierPro.sln`. Both
steps run in `scripts/dev.ps1`.

## Code style

- Keep comments minimal. Only write one when the *why* is non-obvious. Don't
  restate what the code does, don't narrate the current change, don't leave
  `// removed X` breadcrumbs. One short line max — no multi-line comment blocks
  or paragraph docstrings. (Same rule as the root `AGENTS.md`.)
- File-scoped namespaces, 4-space indent, `Nullable` enabled — see `.editorconfig`.
- MVVM via CommunityToolkit.Mvvm (`ObservableObject`, `RelayCommand`,
  `[ObservableProperty]`) — no code-behind view logic beyond wiring.

## Design System

`PalmierPro.Core.Theme.AppThemeTokens` (primitives) + `PalmierPro.App.Theme.AppTheme`
(WinUI adapters) + `Theme.xaml` (XAML `StaticResource`s) are ported verbatim from
`Sources/PalmierPro/UI/AppTheme.swift`, one C# member per Swift token. **All UI
styling must use those tokens** — mirrors the Mac's `AppTheme.swift` rule verbatim.
Never hardcode spacing, font size/weight, corner radius, border width, opacity,
icon size, shadow, or color; add the token first if one doesn't exist.
`ThemeParityTests` (`tests/PalmierPro.Core.Tests/Theme/`) checks `Theme.xaml` against
`AppThemeTokens` — update both together. `FontFamily` is the one token the Mac has
no equivalent of (see Fonts below) and is the documented exception in that test.

## Drag and drop

The Mac's `MediaPanelDropArea` AppKit workaround exists because SwiftUI's
`.onDrop` on a parent view shadows every drop target inside its layout area, even
native `NSDraggingDestination` children. **This is not a problem on Windows.**
XAML drop targets nest correctly: set `AllowDrop` per element and `e.Handled = true`
in inner handlers, and both the outer and inner targets work as expected. Do not
port `MediaPanelDropArea` or invent an equivalent — it would be solving a bug that
doesn't exist on this platform.

## Native engine

`src/PalmierPro.Rendering/native/PalmierEngine.vcxproj` builds via MSBuild, never
`dotnet`. It is intentionally **not** a member of `PalmierPro.sln` — see
`docs/README.md` for why. `src/PalmierPro.Rendering/*.csproj` (the managed
sibling in the same folder) *is* in the solution: it's the P/Invoke layer that
calls into the native DLL, kept separate from the DLL's own build.

## Tests

Layout mirrors `Tests/PalmierProTests/<Area>/<Name>Tests.swift` on the Mac side:
`tests/PalmierPro.Core.Tests/`, `tests/PalmierPro.App.Tests/`. xUnit + Shouldly.
`PalmierPro.App.Tests` is ViewModel/logic only — plain `dotnet test` has no WinUI
host, so WinUI types (`Window`, anything in `Microsoft.UI.Xaml.*`) must never be
instantiated there. GPU-dependent tests carry `[Trait("Category","GPU")]`.

## Voice

Same as the Mac app: direct, technical, calm, confident. Apple HIG-style
terseness over warmth. Never chatty or cute. Never marketing. Lead with the verb
when asking for action; name the thing when reporting state.
