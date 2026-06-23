# Contributing

## How to contribute

The best way to contribute is to open a Github issue. Bug reports, feature requests, ideas are welcome.

With AI coding, human reviews are the bottleneck. We don't have the bandwidth to review large unsolicited PRs.

## Getting Started

### Prerequisites
- macOS 26+
- Xcode 16+
- Swift 6.2 toolchain

### Develop
```bash
git clone https://github.com/palmier-io/palmier-pro
cd palmier-pro

swift build
swift run
```

### Experimental Intel editor-only build

The reduced Intel build is opt-in and excludes Clerk/Convex backend features:

```bash
PALMIER_EDITOR_ONLY=1 swift build --arch x86_64
```

It still requires Swift 6.2 and a macOS 26 SDK because compatibility wrappers must reference macOS 26 SwiftUI APIs before guarding them at runtime.

For a bundled debug build that launches the `.app` and streams OSLog:

```bash
./scripts/dev.sh
```

## Test

```bash
swift test
```

By contributing, you agree your contributions are licensed under [GPLv3](LICENSE).
