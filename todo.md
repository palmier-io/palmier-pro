# Adoption Plan: HyperFrames → Compositor Pro

## Overview
Integrate HyperFrames' catalog, CLI, and agent skills into Compositor Pro to expand video‑creation capabilities while preserving native editing power.

## HyperFrames Video & Storyboard Capabilities Backlog

- [x] **HF-01**: Bidirectional `STORYBOARD.md` Bridge (Markdown parser & exporter for `EditPlan` / `StoryboardReport`)
  - Parse `STORYBOARD.md` (beats, timecodes, voiceover, visual concept, camera/motion, SFX) into native `EditPlan` with shots, script beats, scene narration links, and sound cues.
  - Export active `EditPlan` / storyboard into standard `STORYBOARD.md` Markdown.
  - Wire into `plan_edit` via `import_storyboard_markdown` and `export_storyboard_markdown`.
- [x] **HF-02**: `frame.md` / `design.md` Design Spec & Brand Styling Parser
  - Parse color palettes (hex values), typography rules, fonts, and aspect ratio into project styling presets.
  - Apply design specs to caption templates, text styles, and color grading.
- [x] **HF-03**: `/hyperframes` Motion Playbook & Agent Skill
  - Add `hyperframes-motion-playbook` to `FilmmakingPlaybooks.all` for product launch videos, kinetic typography, and motion graphics.
  - Equip agent with search and placement workflows for catalog motion blocks.
- [ ] **HF-04**: Automated Motion Graphics Track Placement (`insert_and_place_hyperframes_block`)
  - Direct placement and keyframing of kinetic overlays, Lottie vectors, and motion blocks onto timeline tracks.

## Phasing

### Phase 1 (Weeks 0‑4) – Quick Wins
- [ ] HyperFrames catalog wrapper (Swift package)
- [ ] CLI (`compositor-pro init`, `preview`, `render`)
- [ ] WebView‑based live preview
- [ ] `/hyperframes` agent skill

### Phase 2 (Weeks 4‑12) – Mid‑term
- [ ] Adapter import tool (GSAP/Lottie → keyframes)
- [ ] Deterministic rendering test harness (Git LFS baselines)
- [ ] Optional AWS Lambda remote rendering
- [ ] `frame.md` design spec parser / wizard

### Phase 3 (Weeks 12‑24) – Advanced
- [ ] Hybrid authoring (native + HTML composition)
- [ ] Extended catalog & community contribution
- [ ] Cross‑platform (Windows/Linux) support
- [ ] Performance optimizations

## Key Tasks

| # | Task | Responsibility | Est. Effort |
|---|------|----------------|------------|
| 1 | Add HyperFrames catalog wrapper | Swift team | 1 wk |
| 2 | CLI (`compositor-pro`) commands | CLI engineer | 1 wk |
| 3 | Catalog browser UI (drag‑and‑drop) | UI engineer | 2 wk |
|  points | `hyperframes` agent skill | Agent skill maintainer | 1 wk |
| 5 | Adapter import tool | Animation engineer | 2 wk |
| 6 | Deterministic rendering test harness | QA engineer | 2 wk |
| 7 | AWS Lambda optional backend | Backend engineer | 3 wk |
| 8 | `frame.md` parser & wizard | Designer / product | 2 wk |
| 9 | CLI cross‑platform support | DevOps | 2 wk |
|10 | Documentation & migration guide | Technical writer | 1 wk |
|11 | Integration tests & benchmarks | QA / SRE | 1 wk |

## Success Criteria
- ≥70 % of HyperFrames catalog accessible in UI.
- Agent can request video (e.g., “10‑second product intro”) and get a fully authored, renderable project within ~2 min of LLM + 30 s render.
- ≥90 % existing tests pass; new tests cover added functionality.
- Clear docs for CLI commands and UI.

## Dependencies
- Node.js, npm, FFmpeg (for HyperFrames CLI).
- Swift Package Manager.
- CI pipeline for Git LFS baselines.

## Risks & Mitigation
| Risk | Impact | Mitigation |
|------|--------|------------|
| Complexity of headless Chrome | High | Use battle‑tested HyperFrames engine. |
| User adoption (HTML authoring) | Medium | Dual UI: native timeline + optional HTML composer. |
| CI overhead (Git LFS) | Medium | Optional; enforce only for regression tests. |
| Licensing | Low | Both projects Apache 2.0. |

## Next Steps
1. Create a dedicated branch for Phase 1.
2. Implement HyperFrames catalog wrapper and unit tests.
3. Design and implement basic CLI commands.
4. Wire up the Agent skill `/hyperframes`.
5. Set up CI pipeline for baseline video rendering.

## Files to Modify / Add
- `Sources/CompositorPro/HyperFramesCatalog/` (new Swift package)
- `Sources/CompositorPro/CLI/` (new command entry)
- `Sources/CompositorPro/Preview/` (WebView integration)
- `Sources/CompositorPro/Agent/Skills/Hyperframes/` (new skill)
- `Sources/CompositorPro/Tools/AdapterImport/` (new tool)
- Tests under `Tests/CompositorProTests/` for new modules.

## Documentation
- `TODO.md` – work tracking (this file).
- `docs/adoption.md` – detailed design notes.
- UI mockups for catalog browser and preview.
- CLI usage documentation.

---
*Plan created on 2025‑11‑10.*