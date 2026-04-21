# Launch TODO

Pre-launch checklist for Bookface / Hacker News (Show HN), GitHub open source, and Reddit / LinkedIn posts.

Priority tags:
- **[BLOCKER]** — can't launch without.
- **[RECOMMENDED]** — strongly advised, regret if missing on day 1.
- **[NICE]** — defensible to skip for v1, add post-launch.

---

## 1. Distribution

- [x] Apple Developer Program enrolled; Developer ID Application cert in Keychain (`Palmier, Inc. — MMFLRC7562`).
- [x] Codesigning + notarization in `scripts/bundle.sh` (`--sign` and `--dist` modes). Uses `notarytool --keychain-profile palmier-notary`.
- [x] DMG output, notarized + stapled end-to-end. Gatekeeper accepts it. Includes `/Applications` drop shortcut and custom volume icon.
- [ ] **[NICE]** Fancier DMG layout (custom icon positions, background image) via `create-dmg`. Blocked by AppleScript→Finder TCC from automated builds; works fine when invoked from a terminal with Automation permission granted.
- [ ] **[RECOMMENDED]** Make `LSMinimumSystemVersion` (currently 26.0) prominent on the landing page — huge portion of Macs aren't on macOS 26 yet.
- [ ] **[NICE]** Integrate Sparkle for auto-updates.
- [ ] **[NICE]** GitHub Actions release workflow: tag push → signed, notarized DMG attached to a GH release. Main work is secret management (base64-encoded Developer ID p12 + ASC API key).

_Not applicable:_ Universal binary — macOS 26 is Apple Silicon only, so `arm64` is the complete set.
_Not needed:_ `PalmierPro.entitlements` — non-sandboxed Dev ID app with hardened runtime works without a separate entitlements file.

## 2. Product hardening

- [ ] **[BLOCKER]** Add privacy usage descriptions to `Info.plist` for anything the app touches: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSAppleEventsUsageDescription`, etc. macOS crashes on first access without these.
- [ ] **[BLOCKER]** BYOK onboarding polish: empty-state copy that links directly to fal.ai and Anthropic signup pages, explains pricing, shows where keys live (Keychain).
- [ ] **[RECOMMENDED]** Visible error surfacing for network / API failures (fal timeouts, Anthropic 529, no internet) with retry affordances — not silent log lines.
- [ ] **[RECOMMENDED]** Ship a sample `.palmier` project with placeholder assets for first-run exploration.
- [ ] **[RECOMMENDED]** "Send Feedback" menu item that opens email or a form.

## 3. Open-source repo hygiene

- [x] `LICENSE` — GPL-3.0 (canonical text from gnu.org).
- [ ] **[BLOCKER]** Rewrite `README.md` (still the 2-line stub). Needs: hero screenshot/GIF, pitch, features, install, build-from-source, BYOK setup, contributing, license.
- [x] Secrets audit of full git history — `gitleaks` across 141 commits + manual prefix sweep (sk-ant-, fal-, fal_, ghp_, AKIA, AIza, private-key markers) + tracked-file audit. Clean. `.gitignore` hardened with prophylactic entries (.env, *.pem, *.p12, *.p8, AuthKey_*.p8, credentials.json, secrets.json, *.local).
- [ ] **[RECOMMENDED]** `CONTRIBUTING.md` — build instructions, coding style, PR process.
- [ ] **[RECOMMENDED]** `.github/ISSUE_TEMPLATE/` with bug / feature / question templates.
- [ ] **[RECOMMENDED]** GitHub Actions CI: `swift build && swift test` on every PR.
- [ ] **[RECOMMENDED]** `CHANGELOG.md`, tag `v0.1.0`.
- [ ] **[NICE]** `CODE_OF_CONDUCT.md` (Contributor Covenant boilerplate).
- [ ] **[NICE]** Configure GitHub repo settings: description, topics (`macos`, `swift`, `video-editor`, `ai`, `liquid-glass`), homepage link, branch protection on `main`, Discussions enabled.

## 4. Launch assets

- [ ] **[BLOCKER]** Landing page at palmier.io: hero, demo video, download button, BYOK explainer, "open source on GitHub" badge, pricing (even if "free, bring your own keys").
- [ ] **[BLOCKER]** 30–60 second demo video. One magical moment (e.g. describe a clip → AI generates and drops it on the timeline). Record with the real app, tight cuts, no voiceover required.
- [ ] **[BLOCKER]** 3–5 product screenshots (editor with agent panel, timeline in action, generation result). Used in README, landing page, and launch posts.
- [ ] **[RECOMMENDED]** Carry the app icon through to favicon, OG image, and social share preview.
- [ ] **[RECOMMENDED]** Draft Show HN post. Title: `Show HN: Palmier – AI-native Mac video editor (open source)`. Body: what it does, why you built it, what's missing, what feedback you want.
- [ ] **[RECOMMENDED]** Draft Bookface post (YC format: 1-paragraph what, 1-paragraph ask).
- [ ] **[RECOMMENDED]** Identify Reddit targets and read their self-promo rules first:
  - `/r/MacApps` — welcoming
  - `/r/VideoEditing` — skeptical, lead with "open source, BYOK, no subscription"
  - `/r/macOSprogramming`
- [ ] **[NICE]** LinkedIn post — longer, story-driven, founder voice.
- [ ] **[NICE]** Twitter/X thread with the screenshots.

## 5. Legal / privacy

- [ ] **[BLOCKER]** Privacy policy on the landing page. Spell out: no telemetry by default, keys stored in Keychain only, fal and Anthropic receive prompts (link their policies).
- [ ] **[RECOMMENDED]** Terms of use (cheap now, required once you host anything).
- [ ] **[NICE]** Trademark check on "Palmier" via uspto.gov.

## 6. Analytics

- [ ] **[NICE]** PostHog or Mixpanel with **explicit opt-in**. Telemetry without opt-in is the #1 HN complaint on OSS launches.

---

## Critical path (roughly 1 week)

1. **Day 1–2** — Developer certificate, sign/notarize/DMG pipeline in `bundle.sh`, universal binary.
2. **Day 3** — Privacy descriptions, BYOK onboarding copy, sample project, feedback menu item.
3. **Day 4** — LICENSE, real README, screenshots, 45-second demo video.
4. **Day 5** — Landing page (Framer or a simple Vercel page works), privacy policy.
5. **Day 6** — CI workflow, issue templates, secrets audit, tag `v0.1.0`.
6. **Day 7** — Draft Show HN + Bookface + Reddit posts. Schedule the Show HN submission for Tuesday–Thursday, ~9am PT.
