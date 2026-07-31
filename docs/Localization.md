# Localization

Palmier Pro uses UTF-8 `.strings` files and a small runtime wrapper so the app language can follow macOS or use an explicit in-app choice. Language changes take effect after the app restarts. English is the source language.

## Source code

Use `L10n.string("Copy")` for fixed UI copy. Swift interpolation is supported and must remain inside the localized value so translators can reorder it.

Use `L10n.key("Copy")` only when a model stores an app-owned UI label for a view to resolve later with `L10n.string(key:)`. This keeps the source key discoverable without storing localized text in domain state.

Use `Text(verbatim:)` for user content, filenames, release notes, model/provider metadata, timecodes, identifiers, and other values that must not be translated. Do not localize Agent or MCP contracts, persisted values, stable identifiers, machine-readable errors, or analytics values.

After adding or removing UI copy, run:

```bash
scripts/localization/sync.sh
```

This extracts compiler-known Swift strings, adds registered model keys, regenerates `en.lproj/Localizable.strings`, and checks localization integrity. CI rejects a stale English inventory, raw literals in known UI state assignments, malformed catalogs, and incompatible format placeholders. Missing or obsolete target-language entries produce warnings so feature and release PRs can use the English fallback; PRs that change a non-English catalog require complete coverage.

## Adding a language

A language PR adds one or more locale directories:

```text
Sources/PalmierPro/Resources/Localization/
├── en.lproj/
│   ├── Localizable.strings
│   └── InfoPlist.strings
└── fr.lproj/
    ├── Localizable.strings
    └── InfoPlist.strings
```

Copy both files from `en.lproj` into the new locale directory. In `Localizable.strings`, keep every left-hand key unchanged and translate every right-hand value. Do the same for the values in `InfoPlist.strings`. Do not change Swift, `Package.swift`, `Info.plist`, the bundle script, the English inventory, or the language picker. Available languages are discovered from the bundled `.lproj` directories.

Keep interpolation placeholders intact. Positional placeholders such as `%2$@` may be used when the translated sentence needs a different word order. Use complete singular and plural sentences instead of interpolating English suffixes. Translate the meaning, not technical tokens such as product names, keyboard shortcuts, filenames, codecs, model names, or service names unless the source entry clearly treats them as prose.

Validate the result with:

```bash
node scripts/localization/check.mjs
node scripts/localization/check.mjs --require-complete
swift build
```

The strict check is required for a language PR and rejects missing or obsolete entries.

Manually launch the app, select the language in Settings > General, restart, and check menus, settings, editor panels, alerts, empty states, truncation, and Finder project-type text.

The current inventory contains simple strings and format placeholders. A feature that requires locale-specific plural categories must add a shared `.stringsdict` design and matching validation before language-only PRs translate it.
