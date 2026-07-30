# Localization

Palmier Pro ships English and Simplified Chinese UI resources in
`Sources/PalmierPro/Resources/Localization`.

## UI strings

- SwiftUI literal keys such as `Text("Export")` use `Localizable.strings` directly.
- Use `L10n.text(_:)` when a fixed UI key is passed through a reusable view.
- Use `L10n.string(_:)` when an API requires a localized `String`.
- Use `L10n.format(_:_:)` for text that wraps dynamic values. The key uses
  `String(format:)` placeholders, for example `L10n.format("Cancels %@", date)`.

Do not localize project or timeline names, file paths, URLs, commands, prompts,
model names, API/provider names, timecodes, or other user and technical content.
Only localize the fixed text around those values.

## Updating strings

Run the coverage check before opening a pull request:

```bash
node scripts/check-localization.mjs
```

When adding new fixed UI keys, synchronize the English source file, translate
the new keys in `zh-Hans.lproj/Localizable.strings`, and run the check again:

```bash
node scripts/check-localization.mjs --sync-english
node scripts/check-localization.mjs
```

The check fails when a fixed UI candidate is missing or remains untranslated,
when English and Chinese keys drift, when format placeholders differ, or when
protected product and API names are rewritten. CI runs the same command so
future UI changes cannot merge without updating the Simplified Chinese catalog.
