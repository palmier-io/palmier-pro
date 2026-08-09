# Cross-runtime project fixtures

These `.palmier` package fixtures are the compatibility contract between macOS Swift and Linux Rust.

## Layout

- `macos/` fixtures authored or exported from the Swift app
- `linux/` fixtures written by Rust package tests with deterministic IDs

## Rules

- Packages must remain directory bundles ending in `.palmier`
- Preserve unknown entries, corrupt `media.json` bytes when marked, and chat files
- Round-trip must not change timeline meaning for supported features

## Verification

```bash
cd linux
cargo test -p palmier-project --test package
```

On macOS CI, a focused Swift test should open the Linux fixtures and assert decode parity.
