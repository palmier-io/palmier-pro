# Fork: Rebrand + Cut-the-Cords — verified patch plan

Status: **line numbers verified against the working tree at v0.3.5 (2026-06-24).** Every
item below was confirmed by reading the source; no `(verify)` items remain.

GPLv3 lets you fork, rebrand, and release this for free — provided the result stays
GPLv3 with source, preserves the upstream copyright + your change notice, and uses your
own name/marks (trademarks aren't licensed). Personal use / GitHub release = clear; the
App Store is the only place GPLv3 can't go.

Build prerequisite: **Swift 6.2 / Xcode 26**, macOS 26, arm64.

## 0. Tokens to choose

| Token | Replaces | Pick |
|---|---|---|
| `<APP_NAME>` | `Palmier Pro` (display name) | e.g. `Reel Cut` |
| `<MODULE>` | `PalmierPro` (SPM product/target/module = `CFBundleExecutable` = binary) | PascalCase, e.g. `ReelCut` |
| `<app-slug>` | `palmier-pro` (MCP server name, `.mcpb` file) | e.g. `reel-cut` |
| `<BUNDLE_ID>` | `io.palmier.pro` | reverse-DNS, e.g. `com.you.reelcut` |
| `<BUNDLE_ID_BASE>` | `io.palmier` (root of UTI `io.palmier.project`) | `com.you` |
| `<ORG>` / `<DOMAIN>` / `<REPO>` | `Palmier, Inc.` / `palmier.io` / `palmier-io/palmier-pro` | yours |
| `<TEAM_ID>` / `<NOTARY_PROFILE>` | `MMFLRC7562` / `palmier-notary` | your Apple Team ID / notarytool profile |
| `<EDDSA_PUBKEY>` | `Jh56mT+7YZSRsLylQIPyP+4/ahRtTPzfQQaKDZoBsio=` | generate fresh (below) |
| `<url-scheme>` / `<app-ext>` | `palmier` / `.palmier` | **recommend keeping both** (app-private; changing breaks OAuth callback + existing project files) |

Sparkle keypair: after a build, run `.build/artifacts/sparkle/Sparkle/bin/generate_keys`
→ public key → `Info.plist SUPublicEDKey`; private key stays in your Keychain
(`bundle.sh:197` `sign_update` reads it). **Both or neither** — mismatched keys fail every update.

Backend choice (drives §2.4): **(A) drop it → BYO-Anthropic-key / gateway only** (leave
`SENTRY_DSN`/`CLERK_PUBLISHABLE_KEY`/`CONVEX_*` unset; app degrades gracefully, no crash —
`AccountService.swift:143` sets `isMisconfigured`) — recommended; or **(B) run your own**
Clerk+Convex. The `bundle.sh:66` "fatalError" warning is **stale/wrong** — it degrades.

## 1. Rebrand

### Info.plist — `Sources/PalmierPro/Resources/Info.plist`
| Line | Current | → |
|---|---|---|
| 6 | `Palmier Pro` (CFBundleDisplayName) | `<APP_NAME>` |
| 11 | `Palmier Project` (CFBundleTypeName) | `<APP_NAME> Project` |
| 16 | `io.palmier.project` (LSItemContentTypes) | `<BUNDLE_ID_BASE>.project` |
| 21 | `PalmierPro.VideoProject` (NSDocumentClass) | `<MODULE>.VideoProject` |
| 25 | `PalmierPro` (CFBundleExecutable) | `<MODULE>` |
| 29 | `io.palmier.pro` (CFBundleIdentifier) | `<BUNDLE_ID>` |
| 31 | `Palmier Pro` (CFBundleName) | `<APP_NAME>` |
| 40 | `io.palmier.pro` (CFBundleURLName) | `<BUNDLE_ID>` |
| 43 | `palmier` (CFBundleURLSchemes) | keep, or `<url-scheme>` |
| 56 | SUFeedURL → Palmier appcast | §2.1 |
| 58 | SUPublicEDKey | §2.1 |
| 67 | `Palmier Project` (UTTypeDescription) | `<APP_NAME> Project` |
| 69 | `io.palmier.project` (UTTypeIdentifier) | `<BUNDLE_ID_BASE>.project` (== line 16) |
| 74 | `palmier` (filename-extension) | keep `palmier` unless severing the file format |

### Runtime counterparts (must change in lockstep with the plist)
| File:line | Current | → |
|---|---|---|
| `Utilities/Constants.swift:105` | `fileExtension = "palmier"` | `<app-ext>` (keep `palmier`) |
| `Utilities/Constants.swift:107` | `typeIdentifier = "io.palmier.project"` | `<BUNDLE_ID_BASE>.project` (== plist 16/69) |
| `Utilities/Constants.swift:117` | `Documents/Palmier Pro` (storage dir) | `Documents/<APP_NAME>` |
| `Utilities/Log.swift:10` | `subsystem = "io.palmier.pro"` | `<BUNDLE_ID>` (also `dev.sh:21,34`) |
| `Utilities/KeychainStore.swift:5` | `?? "io.palmier.pro"` (bundle-id fallback) | `<BUNDLE_ID>` (auto-migrates off CFBundleIdentifier) |
| `Agent/MCP/MCPService.swift:11` | `io.palmier.pro.mcp.enabled` | `<BUNDLE_ID>.mcp.enabled` |
| `Telemetry/Telemetry.swift:8` | `io.palmier.pro.telemetry.enabled` | `<BUNDLE_ID>.telemetry.enabled` |
| `App/AppNotifications.swift:6` | `io.palmier.pro.notifications.enabled` | `<BUNDLE_ID>.notifications.enabled` |
| `Preview/AlphaVideoNormalizer.swift:92` | `io.palmier.alpha-normalize` (GCD label) | `<BUNDLE_ID_BASE>.alpha-normalize` (cosmetic) |

> Changing UserDefaults keys resets those prefs to default (fine for a fork).

### Package.swift
`name:` (6), `.executable` (9), target `name:` (24) → `<MODULE>`; `Resources/MCPB/palmier-pro.mcpb`
(45) → `<app-slug>.mcpb`; optionally rename `Sources/PalmierPro` dir (36). The executable
rename must move together with `Info.plist:25/21` and `bundle.sh:46,52,81` or the `.app`
won't launch (`bundle.sh:81` resource bundle is `PalmierPro_PalmierPro.bundle` → `<MODULE>_<MODULE>.bundle`).

### User-facing strings (`Palmier Pro` → `<APP_NAME>`, `Palmier` → `<APP_NAME>`)
`App/MainMenu.swift:22,23,31`; `Project/WelcomeOverlay.swift:25`; `Project/HomeView.swift:159,161,221`
(`:221` is `window.title`); `Settings/PrivacyPane.swift:25`; `Editor/Tour/TourController.swift:157`;
`App/AppNotifications.swift:77`; `Help/MCPInstructionsPane.swift:84`; `MediaPanel/MediaTab/AssetThumbnailView.swift:265`;
`Preview/PreviewContainerView.swift:441,442`; `Generation/GenerationBackend.swift:132`;
`Generation/Edit/EditSubmitter.swift:86`; `Agent/Tools/ToolExecutor+Generate.swift:7,199,320`;
`Agent/Tools/ToolDefinitions.swift:48,439`; `Agent/Tools/AgentInstructions.swift:5,34`;
`Export/ExportView.swift:8`; `Resources/Changelog/changelog.json:11`; `Account/AccountService.swift:378`
(`domain: "Palmier.Feedback"`). **Leave** `Settings/AgentPane.swift:11` (Anthropic console, 3rd-party).

### MCP protocol surface (rename consistently — shared with the palmier-pro-plugin)
`Agent/MCP/MCPService.swift:38` server `name: "palmier-pro"` → `<app-slug>`; `:100,106,124,127`
`palmier://models/*` URIs; `Help/MCPInstructionsPane.swift:9,13,20,33,55,145`; `mcpb/manifest.json:3,4,6,7,10,11,13`.
**→ the palmier-pro-plugin's `SERVER_NAME` must match the new `<app-slug>`.** OAuth: `AccountService.swift:160,161`
(`palmier://callback` / scheme `palmier`) must match `Info.plist:43` — keep `palmier` = no change.
Internal drag schemes `MediaTab+Drag.swift:8,9` (`palmier-folder://`,`palmier-asset://`) are app-private — leave.

### Binary assets to REPLACE (not text-editable)
`Resources/AppIcon.icon/Assets/palmier-logo.png` (+ `AppIcon.icon/icon.json:27,28` names),
`Resources/AppIcon.icns`, `Resources/AppIcon.png`, `mcpb/icon.png`, the prebuilt
`Resources/MCPB/palmier-pro.mcpb` (rebuild + rename), `assets/palmier-ui.png` (README shot).
**Keep** `assets/macos-badge.png` (generic) and all `Resources/Fonts/*` licenses.

## 2. Cut the cords

### 2.1 Sparkle (MUST — both edits or neither)
`Info.plist:56` SUFeedURL → your appcast; `:58` SUPublicEDKey → `<EDDSA_PUBKEY>`. To disable
updates entirely: delete SUFeedURL (55-56) — `App/Updater.swift:15-17` no-ops without it.
Regenerate `appcast.xml` (title + ~40 enclosure URLs) and `release.sh:139,168` → `<REPO>`/`<MODULE>.dmg`.

### 2.2 Build scripts
`bundle.sh:36` signing identity, `:37` notary profile, `:40-42,46,52,81,88-89,186,190` artifact/app/dmg/bundle/mcpb
names + `-volname` → `<MODULE>`/`<app-slug>`/`<APP_NAME>`; `dev.sh:17,21,25,27,32,34` app name + OSLog subsystem;
`release.sh:32-34,68,101,139,168` plist/appcast/dmg paths + URLs.

### 2.3 Sentry (build-time DSN; absent from repo)
Mode A: leave `SENTRY_DSN` unset → `bundle.sh:55-60` no-op → `Telemetry.swift:27` bails. Optional opt-in
flip at `Telemetry.swift:13`; `releaseName` at `:44`. dSYM upload `bundle.sh:119-129` (your `SENTRY_ORG/PROJECT` or skip).

### 2.4 Clerk + Convex (build-time env; absent from repo)
`bundle.sh:74-76` inject `PalmierClerkPublishableKey`/`PalmierConvexDeploymentURL`/`PalmierConvexHttpURL`.
Mode A: leave unset → `BackendConfig.swift:8-10` `isConfigured=false` → `AccountService.swift:140-154` degrades
(no sign-in/hosted-AI/samples/billing/feedback; BYO-Anthropic-key direct to `api.anthropic.com`, or the gateway from
Change 1). All other Palmier endpoints (samples, generation proxy, feedback, Stripe) ride this one Convex client.

### 2.5 HuggingFace model
`Search/SearchIndexConfig.swift:6` `hostedURL` → your mirror (keep pinned SHA-256s `:31,37,41` if byte-identical;
recompute if re-converted). Disable search instead: `:9` `?? true` → `?? false`. DEBUG override key
`searchIndexModelBaseURL` at `:14-19`.

### 2.6 Docs/contact URLs
`Editor/Tour/TourOverlay.swift:12` `palmier.io/docs`; README/FAQ/CONTRIBUTING socials + clone URLs.

## 3. GPLv3 compliance (don't skip)
No per-file Swift headers exist, so: **keep `LICENSE` verbatim; preserve the Palmier copyright; add yours;
carry a dated change notice.**
- `README.md` license section (~109-113): keep `Copyright (C) 2026 Palmier, Inc.`, add `Modifications Copyright (C) <YEAR> <ORG>`, state it's a fork, link CHANGES.md/NOTICE.
- New `NOTICE` + `CHANGES.md` (GPLv3 §5(a) dated change notice).
- `CONTRIBUTING.md:31` keep the GPLv3 grant; fix clone URLs. Keep every font license.

## 4. Apply order + verify
Decisions → Package/bundle identity (+`swift build` to catch module/path drift) → scripts → strings → assets →
cords → notices → build+notarize. Then:
- Residual grep: `grep -rniE 'palmier|io\.palmier\.pro|PalmierPro' --include='*.swift' --include='*.plist' --include='*.json' --include='*.sh' --include='*.md' --include='*.xml' . | grep -vi Resources/Fonts | grep -vi console.anthropic`
- Built plist: `PlistBuddy -c 'Print :CFBundleIdentifier' …` / `:SUFeedURL` / `:SUPublicEDKey` / confirm `:SentryDSN` & `:PalmierConvexHttpURL` absent (mode A).
- Little Snitch fresh launch: nothing hits `palmier.io`, `*.convex.*` you don't own, `*.sentry.io`, Clerk, `huggingface.co/palmier-io`.
- `codesign --verify --deep --strict` + `spctl -a -vvv`.

## 5. Effort
~35-40 files. Mechanical find/replace ~1-2 h (`swift build` after identity catches the only build-breaking class).
Real work: icon/logo design (long pole), Sparkle keygen (5 min) + appcast hosting (~1 h), `.mcpb` rebuild (~30 min).
Mode A backend ≈ 0 extra; Mode B = multi-day-to-weeks. **Realistic: ~1 day for a clean Mode-A rebrand** if artwork's ready.
