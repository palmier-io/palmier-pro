# Native interface, localization, and resources

Read for SwiftUI/AppKit, interaction, styling/copy, bundled resources, or packaging.

## Native state and interaction

- Views render state and forward user intent to shared domain operations. Keep filesystem work, processing, mutations, and orchestration out of view bodies.
- Observable UI state stays on the main actor; background results cross as immutable values. Observe the smallest needed state surface, especially progress/meters/hover/playback.
- Do not start persistent side effects from `body`. Use lifecycle-aware tasks/controllers with owned cancellation and teardown.
- Preserve native keyboard focus, Escape/Return, menus, window restoration, undo, drag state, sheets, and close confirmation. Delegate/completion contracts finish exactly once, including missing targets.
- Do not assume AppKit/AVFoundation callbacks run on the main thread unless documented. Revalidate lifecycle and identity before applying async results.
- Test mouse/keyboard modifiers, Escape/dismissal, disabled/empty states, focus/selection changes, overlapping gestures, mouse-up after cancellation, deactivation, sleep, and undo when affected.
- UI verification is manual: provide setup, actions, expected results, and edge/lifecycle cases. A build or unit pass does not establish a UI pass.

## AppTheme

- All styling uses `Sources/CompositorPro/UI/AppTheme.swift`; add missing tokens there first, never hardcode replacements in views.
- Use `AppTheme.Spacing`, `FontSize`, `FontWeight`, `Radius`, `BorderWidth`, `Opacity`, `IconSize`, `Text`, `Border`, `Background`, and `Anim` for their respective styling values.
- Use `AppTheme.Shadow` through `.shadow(AppTheme.Shadow.md)` or the appropriate existing token.
- Product copy is direct, technical, calm, and native-Mac terse; never chatty, cute, or marketing-oriented.

## Drag and drop

- On macOS 26, a parent SwiftUI `.onDrop` shadows every child drop target, including native registered destinations.
- A target containing other targets must use native AppKit; use `Sources/CompositorPro/MediaPanel/MediaTab/MediaPanelDropArea.swift`.
- Leaf targets may use SwiftUI `.onDrop`. Never stack parent/child SwiftUI `.onDrop` modifiers.

## Localization and bundle layout

- Localize fixed app-owned UI copy with `L10n.string`; keep interpolation inside the value for translation reordering.
- Register model-held UI labels with `L10n.key`, resolve with `L10n.string(key:)` at the UI boundary. Render user content, filenames, technical values, and provider metadata verbatim.
- Never localize Agent/MCP contracts, persistence values, stable IDs, machine errors/statuses, or analytics.
- Run `zsh scripts/localization/sync.sh` after copy changes. Generated `en.lproj/Localizable.strings` is the source inventory; never edit it manually.
- Language changes add only complete `<locale>.lproj` directories with `Localizable.strings` and `InfoPlist.strings`; translate values, not keys, and do not add production language lists. Require complete coverage for changed non-English catalogs.
- Use `Sources/CompositorPro/Utilities/BundledResource.swift` for shared lookup, off-main when lookup performs filesystem access. Do not invent feature-specific probes or `#if DEBUG` resource behavior.
- Verify packaged `.app`, `swift run`, and SwiftPM-test layouts separately. Update `Package.swift`, bundle scripts, and tests when resources change; inspect the final app layout.
- Keep optional code/resources buildable with and without the relevant trait. Native minimum-OS/runtime support is not proved by a build on a newer host.

Reference: [SwiftUI performance in Instruments](https://developer.apple.com/videos/play/wwdc2025/306/).
