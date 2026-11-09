# Explainer production TODO

Goal: produce researched, narration-led explainers from one brief, with mandatory storyboard review before full production and no user “continue” prompts. Every image or video must be used at most once within the finished video. No images or videos may reveal people's faces.

Completed tasks, release gates, and verification evidence have been moved to [done.md](done.md).

## Remaining user requirements

- [ ] Only after those gates pass, build/verify a Developer ID-signed app and safely update the existing Compositor Pro installation (signed app update section). Do not substitute ad-hoc signing or mark blocked signing complete.

Based on [Malaysia chip explainer capability audit](docs/malaysia-chip-explainer-capability-audit.md). Reference: [CaspianReport's Malaysia semiconductor explainer](https://www.youtube.com/watch?v=zH5WptvpLCY).

## Implementation principles

- Reuse existing edit plans, retrieval, speech, assembly, finishing, export, package coordination, and undo. Do not build a parallel editor.
- The model chooses the argument, evidence, and scene purpose. The app owns timing, rendering, dependencies, jobs, and delivery state.
- Authored script, claims, and graphic specifications each have one authoritative owner. Resolved timing and rendered media are derived outputs with explicit revision keys and invalidation.
- UI and Agent callers use the same domain operations. Validate before mutation; commit coherent changes through shared undo.
- Keep filesystem work, media processing, and blocking framework calls off the main actor. Route live package changes through `ProjectPackageCoordinator`.
- Start with supplied research, licensed assets, one narrator, landscape output, and no paid generation. A built-in browser, voice cloning, sponsor recreation, and exact channel-style copying are not initial requirements.
- Fewer user prompts is the objective, not fewer internal tool calls. Measure both separately.
- Storyboard approval is an intentional review checkpoint, not a “continue” prompt. Combine script approval and consequential blockers into that review where possible.

## Golden rule for the Agent — mandatory visual uniqueness

> Never use the same image or video more than once in the same finished video. Check canonical source identity, not only clip IDs, filenames, or download URLs. A crop, different trim, speed change, recolor, resize, re-encode, or duplicate import does not make it a new asset. If unique suitable coverage is unavailable, report a blocker; never silently repeat footage.

This is a hard acceptance condition, not a recommendation or a score penalty. Audio is outside this rule. Different generated scenes may share vector geometry, theme, or geographic data, but must not hide repeated image/video inputs inside separate composites or baked outputs. One continuous visual occurrence can contain successive reveals; replaying it later is reuse. Storyboard thumbnails and review previews do not count as extra uses in the final output. This product rule is stricter than matching the reference's recurring visual environments.

Agent guidance now includes this machine-facing rule and explicitly covers source identity, composites, nested timelines, continuous splits, and preview/audio exclusions. Hard shared enforcement remains task 5b; prompt compliance is not proof of output uniqueness.

## Golden rule for the Agent — no revealed faces

> Do not use images or videos with people's faces revealed. Inspect actual selected source spans and final framing, including motion, crowds, reflections, photographs, and screens. Prefer objects, landscapes, hands, back-facing people, and silhouettes without facial detail. Unknown inspection coverage is unresolved; choose verified faceless coverage or report a blocker. Filenames, search tags, thumbnails, low resolution, fleeting appearances, and unverified crops are not proof.

**What/how:** Agent guidance applies this rule during discovery, storyboard selection, replacement, and final review. Inspect stills directly and selected video spans continuously where possible. Sparse frames cannot certify absence of faces between samples. Native face detection may assist a future bounded inspection workflow but must not be described as complete coverage or identity/privacy certification. Task 9 must retain inspection coverage; tasks 5a, 8, and 12 must block approval/build/delivery for unresolved or revealed faces. The rule is implemented as guidance, not an automatic face detector or hard output gate.

Storyboard guidance now requires explicit review of narration, order, proposed visuals, pacing, sources, rights, and grouped blockers before full production. Native persistent storyboard/approval enforcement remains tasks 5–5a and 8. A material revision requires renewed approval; approval cannot override either visual rule.

**Guidance verification:** `swift build` and `swift test --filter 'ExplainerVisualRulesTests|ExplainerContractsMCPTests|ClipIdentityMCPTests'` passed (9 tests in 3 suites). Tests protect mandatory review and both visual rules. No automatic face inspection, native storyboard UI, or production-gate verification claimed.

## Rebrand & backend removal

### R2. Rename Palmier traces to compositor-pro

- [ ] Rename Palmier-brand artifacts to the Compositor Pro identity.

**What:** 77 references to the `.palmier` project-package extension exist
across source and tests, plus `mode: "palmier"` / `format: "Palmier"` in the
export contract, the `X-Palmier-Project-Id` header, MCP server id
`palmier-pro` (`MCPService.swift`, `mcpb/manifest.json`, help pane), author /
homepage fields pointing at Palmier.io, a legacy `Documents/Palmier Pro`
support directory, telemetry strings, and `BINARY_LICENSE.md` headers.

**How:**
- Decide the product identity first: package type identifier, file extension,
  UTI, bundle name — then migrate on load (rename-on-open, backward-compatible
  open of `.palmier` files, preserve package contents). Do not break existing
  user projects.
- Rename contracts atomically: export `mode`, format/receipt fields, the MCP
  server name, the project header, `mcpb/manifest.json` author/homepage, and
  the legacy support-directory lookup (rename on access).
- Sweep code, tests, docs, and localization marketing strings (welcome,
  notifications, MCP instructions) to the new name; any surviving `.palmier`
  string must be an explicit legacy migration shim with a comment.

**Done when:** Grep for `palmier` across source, tests, docs, and configs
matches only documented legacy shims; a `.palmier` project opens and saves
under the new identity.

### R3. Re-skin the editor UI to look distinct from Palmier Pro

- [ ] Ship a new editor skin so Compositor Pro reads as its own product.

**What:** The layout, palette, type scale, and motion language are inherited
from the Palmier Pro codebase. A clone look is off-brand and confuses users
who follow both products.

**How:**
- Define a new `AppTheme` design (palette, typography, spacing, radii, panel
  structure, toolbar layout, timeline density) in one theme file following the
  existing `AppTheme` token discipline — no hardcoded numeric styling.
- Keep every feature reachable in the new layout (Captions style gallery,
  Storyboard review, Account removal per R1, Export); preserve `L10n` keys and
  keyboard behavior.
- Ship screenshot pairs (old vs new: workspace, timeline, inspector, export)
  with the change; user confirms the new skin is legible and distinct.

**Done when:** The app renders with the new theme everywhere, AppTheme owns
all styling constants, and user-reviewed screenshots confirm the distinct look.

## Signed app update

- [ ] After implementation and repeated deep verification, build the release app with Developer ID signing, verify its signature/resources, and safely replace the existing installation.
- [ ] Preserve the current app until the complete signed replacement is ready; never substitute an ad-hoc build for the requested signed release.

**Preflight (2026-11-08):** Existing installation is `/Applications/CompositorPro.app`, bundle ID `io.compositor.pro`, version `0.7.6`. `security find-identity -v -p codesigning` returned `0 valid identities found`. Developer ID certificate and matching private key must be restored or unlocked through Keychain Access before signing. The bundle script's default `scripts/Palmier_Pro_Developer_ID.provisionprofile` is also absent; configured overrides were not inspected. No release signing, app replacement, or installed-runtime verification performed. Implementation, full production gates, and manual UI review remain incomplete.

**Repeated signing preflight:** Still `0 valid identities found`. No `SIGNING_IDENTITY`, `PROVISION_PROFILE`, or `NOTARY_PROFILE` environment override is configured, and no repository `.provisionprofile` exists. Signed release remains blocked; the installed app remains untouched.
